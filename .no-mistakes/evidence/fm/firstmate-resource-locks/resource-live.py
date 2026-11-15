import os, pathlib, subprocess, time, json, signal, shutil

root = pathlib.Path.cwd()
lab = root / '.live-validation' / 'locks'
lab.mkdir()
(lab/'config').mkdir()
(lab/'run').mkdir()
evidence = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E5G3VE4WRF2AH7TSMB9MDJ')
script = str(root/'bin/fm-resource-lock.sh')
env = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ['TASKS_AXI_FILE','TASKS_AXI_BACKEND'])}
env.update(FM_HOME=str(lab), XDG_RUNTIME_DIR=str(lab/'run'), FM_RESOURCE_LOCK_NOW='12:00', FM_RESOURCE_LOCK_POLL_SECS='0.05')
declaration = lab/'config/resource-locks'
declaration.write_text('suite 2 22:00-09:00=1 full test suites\ngpu 1 GPU commands\n')
log = open(evidence/'resource-live.log','w',buffering=1)
processes = []
def note(s):
    print(s, file=log)
def run(args, **kw):
    r = subprocess.run(args, env=env, text=True, capture_output=True, timeout=15, **kw)
    note('$ '+repr(args)+'\nexit='+str(r.returncode)+'\n'+r.stdout+r.stderr)
    return r
def start(args, tag, now='12:00'):
    err=open(lab/(tag+'.stderr'),'w')
    p=subprocess.Popen(args,env=dict(env,FM_RESOURCE_LOCK_NOW=now),stdout=err,stderr=err,start_new_session=True)
    processes.append(p)
    note('$ '+repr(args)+' time='+now+' pid='+str(p.pid))
    return p
def waitfor(f):
    until=time.monotonic()+12
    while time.monotonic()<until:
        if f(): return
        time.sleep(.04)
    raise AssertionError('Timed out waiting for observable state')
def held(path):
    return subprocess.run(['flock','-n',str(lab/'run'/path),'true']).returncode != 0
def worker(tag):
    return ['sh','-c',': > "$1.started"; while [ ! -e "$1.release" ]; do sleep .05; done', 'job',str(lab/tag)]
def started(tag): return (lab/(tag+'.started')).exists()
def release(tag): (lab/(tag+'.release')).touch()
def wrap(resource,command): return [script,'run',resource,'--']+command
try:
    brief=run([script,'brief'])
    assert brief.returncode==0
    (evidence/'resource-brief.md').write_text(brief.stdout)
    for kind,flags in [('ship',['--mode','local-only']),('scout',['--scout'])]:
        r=run([str(root/'bin/fm-brief.sh'),kind,'lab-project']+flags)
        assert r.returncode==0
        text=(lab/'data'/kind/'brief.md').read_text()
        section=text[text.index('# Heavy commands (resource locks)'):]
        note('GENERATED '+kind+' BRIEF RESOURCE SECTION:\n'+section)
    # Two day jobs really run together; a third waits.
    a=start(wrap('suite',worker('day-a')),'day-a')
    b=start(wrap('suite',worker('day-b')),'day-b')
    waitfor(lambda: started('day-a') and started('day-b'))
    c=start(wrap('suite',worker('day-c')),'day-c')
    waitfor(lambda: 'waiting for suite' in (lab/'day-c.stderr').read_text())
    assert not started('day-c')
    note('OBSERVED day-a and day-b started; day-c waits; both suite slot files locked='+str([held('suite-slot-1.lock'),held('suite-slot-2.lock')]))
    release('day-a'); assert a.wait(timeout=3)==0
    waitfor(lambda: started('day-c'))
    note('OBSERVED day-c starts after day-a releases')
    release('day-b'); release('day-c'); b.wait(timeout=3); c.wait(timeout=3)
    # A job holding slot 2 from day prevents a night job taking free slot 1.
    day=start(['flock',str(lab/'run/suite-slot-2.lock')]+worker('carry'),'carry')
    waitfor(lambda: started('carry'))
    night=start(wrap('suite',worker('night')),'night','23:00')
    waitfor(lambda: 'waiting for suite' in (lab/'night.stderr').read_text())
    assert not started('night')
    note('OBSERVED night job waits with slot 1 free and day holder on slot 2: '+(lab/'night.stderr').read_text())
    release('carry'); day.wait(timeout=3); waitfor(lambda: started('night'))
    release('night'); night.wait(timeout=3)
    # Ordered multi-resource jobs retain the outer lock and both finish.
    gpu=start(['flock',str(lab/'run/gpu.lock')]+worker('plain-gpu'),'plain-gpu')
    waitfor(lambda: started('plain-gpu'))
    first=start(wrap('suite',wrap('gpu',worker('nested-a'))),'nested-a','23:00')
    waitfor(lambda: 'waiting for gpu' in (lab/'nested-a.stderr').read_text())
    second=start(wrap('suite',wrap('gpu',worker('nested-b'))),'nested-b','23:00')
    waitfor(lambda: 'waiting for suite' in (lab/'nested-b.stderr').read_text())
    assert not started('nested-a') and not started('nested-b')
    note('OBSERVED nested-a retains suite while waiting for plain GPU holder; nested-b waits for suite')
    release('plain-gpu'); gpu.wait(timeout=3); waitfor(lambda: started('nested-a'))
    assert held('gpu.lock') and not started('nested-b')
    note('OBSERVED nested-a runs holding GPU and suite; nested-b still waits')
    release('nested-a'); first.wait(timeout=3); waitfor(lambda: started('nested-b'))
    release('nested-b'); second.wait(timeout=3)
    note('OBSERVED both ordered competing jobs completed; GPU and both suite slots now free='+str([not held(p) for p in ['gpu.lock','suite-slot-1.lock','suite-slot-2.lock']]))
    # Parent exit leaves the descendant holding the slot until it exits.
    r=run(wrap('gpu',['sh','-c','(while [ ! -e "$1.child-release" ]; do sleep .05; done) </dev/null >/dev/null 2>&1 & echo parent-exited', 'parent',str(lab)]))
    assert r.returncode==0 and held('gpu.lock')
    childwait=start(wrap('gpu',worker('childwait')),'childwait')
    waitfor(lambda: 'waiting for gpu' in (lab/'childwait.stderr').read_text())
    assert not started('childwait')
    note('OBSERVED parent exited but descendant retains GPU; next command waits')
    (lab.with_suffix('.child-release')).touch()
    waitfor(lambda: started('childwait')); release('childwait'); childwait.wait(timeout=3)
    note('OBSERVED descendant exit releases GPU and waiter runs')
    r=run(wrap('gpu',['sh','-c','printf "arg=<%s>\\n" "$@"; exit 7','job','two words','','last']))
    assert r.returncode==7 and 'arg=<two words>\narg=<>\narg=<last>' in r.stdout
    # Invalid declarations fail before running commands or writing partial briefs.
    for label,value in [('zero-window','suite 2 22:00-09:00=0 full suites\n'),('duplicate','suite 1 suites\nsuite 2 suites\n'),('bad-name','suite-slot-1 2 suites\n')]:
        declaration.write_text(value)
        r=run(wrap('suite',['touch',str(lab/'MUST-NOT-RUN')]))
        assert r.returncode==1 and not (lab/'MUST-NOT-RUN').exists()
        r=run([str(root/'bin/fm-brief.sh'),label,'lab-project','--scout'])
        assert r.returncode==1 and not (lab/'data'/label).exists()
    declaration.write_text('suite 2 full suites\ngpu 1 GPU commands\n')
    r=run(wrap('unknown',['touch',str(lab/'MUST-NOT-RUN')]))
    assert r.returncode==1 and not (lab/'MUST-NOT-RUN').exists()
    r=run([script,'list']); assert r.returncode==2
    note('OBSERVED invalid declarations and unknown resources execute no payload and create no partial brief; removed list command exits 2')
    for f in sorted(lab.glob('*.stderr')): note(f.name+':\n'+f.read_text())
    note('ALL DIRECT PRODUCT SCENARIOS PASSED')
finally:
    (lab.with_suffix('.child-release')).touch()
    for p in processes:
        if p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            p.wait(timeout=3)
    log.close()
