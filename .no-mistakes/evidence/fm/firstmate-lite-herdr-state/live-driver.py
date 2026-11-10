import os, sys, json, time, subprocess, shutil, re
from pathlib import Path
ROOT=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73T6KEWT536RR3MJ2AYEEYA'); E=Path('/home/runkai/.no-mistakes/evidence/01M73T6KEWT536RR3MJ2AYEEYA')
R=ROOT/'.test-runtime/live'; R.mkdir(parents=True,exist_ok=True)
SESSION='fm-lab-v'; HELPER=ROOT/'bin/fm-herdr-lab.sh'
env=dict(os.environ)
for k in list(env):
    if k.startswith('HERDR_') or k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_CONFIG_OVERRIDE','FM_DATA_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_HOME','FM_GATE_REFUSE_BYPASS','FM_TASK_ID']:
        env.pop(k,None)
(R/'user-home').mkdir(exist_ok=True)
env.update(HOME=str(R/'user-home'),XDG_DATA_HOME=str(R/'user-home/data'),XDG_CACHE_HOME=str(R/'user-home/cache'),HERDR_CONFIG_PATH=str(E/'h/herdr/lab-config.toml'),XDG_CONFIG_HOME=str(E/'h'), FM_HERDR_LAB_STATE_DIR=str(R/'lab-state'), TMPDIR=str(ROOT/'.test-runtime'))
original_path=env['PATH']; children=[]; provisioned=False
log=open(E/'live-product.log','w',buffering=1)
def record(label,value):
    log.write(label+'\n'+(value if isinstance(value,str) else json.dumps(value,indent=2))+'\n'); print(label,flush=True)
def run(args,check=True,ee=None,show=True):
    p=subprocess.run([str(a) for a in args],env=ee or env,cwd=ROOT,capture_output=True,text=True,timeout=35)
    if show: record('$ '+' '.join(str(a) for a in args), p.stdout+p.stderr)
    if check and p.returncode: raise RuntimeError(f'command rc={p.returncode}: {args}: {p.stdout} {p.stderr}')
    return p

def lab(*args,check=True,show=True):return run([HELPER,'run',SESSION,*args],check=check,show=show)
def report(pane,state):lab('pane','report-agent',pane,'--source','fm-live-validation','--agent','claude','--state',state)
def wait_for(predicate,label,seconds=18):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        if predicate():return
        time.sleep(.15)
    raise AssertionError(label)
def home(name,panes):
    h=R/name; run([ROOT/'bin/fm-lab-home.sh','create',h])
    for task,pane in panes.items():
        (h/'state'/f'{task}.meta').write_text(f'window={SESSION}:{pane}\nbackend=herdr\nkind=scout\nharness=claude\nworktree={R}\n')
    return h
def ee(h):
    return {**env,'FM_HOME':str(h),'PATH':str(R/'shim')+':'+original_path,'FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_SECONDMATE_LIVENESS_SECS':'99999999','FM_BACKEND_HERDR_EVENTS_FORCE':'0','FM_BUSY_TURN_MAX_SECS':'1','LIVE_NOTICE_LOG':str(E/'live-notifications.jsonl'),'LIVE_HELPER':str(HELPER),'LIVE_SESSION':SESSION,'LIVE_ORIGINAL_PATH':original_path}
def start(h):
    f=open(h/'watch.log','w'); proc=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env=ee(h),cwd=ROOT,stdout=f,stderr=subprocess.STDOUT)
    children.append((proc,f));return proc

def quiet_cycle(h,proc):
    beat=h/'state/.last-watcher-beat'
    wait_for(lambda:beat.exists() or proc.poll() is not None,'watcher did not start')
    assert proc.poll() is None,(h/'watch.log').read_text()
    first=beat.stat().st_mtime_ns
    wait_for(lambda:proc.poll() is not None or beat.stat().st_mtime_ns!=first,'no complete poll cycle')
    assert proc.poll() is None,(h/'watch.log').read_text()
    record('Watcher completed a quiet cycle',{'home':h.name,'output':(h/'watch.log').read_text(),'wake_queue_exists':(h/'state/.wake-queue').exists()})
def finished(h,proc,contains):
    wait_for(lambda:proc.poll() is not None,'watcher did not deliver expected wake')
    out=(h/'watch.log').read_text(); record('Watcher delivered '+h.name,out)
    assert proc.returncode==0 and contains in out,out
    record('Persisted wake queue '+h.name,(h/'state/.wake-queue').read_text())
    return out

def ack(h):
    p=run([ROOT/'bin/fm-wake-drain.sh'],ee=ee(h))
    command=re.search(r'^WAKE_ACK_REQUIRED: (.*)$',p.stderr,re.M)
    assert command,p.stderr
    import shlex
    args=shlex.split(command.group(1))
    # Emitted command may carry env prefixes. Execute its supported CLI options.
    start=args.index('--ack-through')
    run([ROOT/'bin/fm-wake-drain.sh',*args[start:]],ee=ee(h))
def notice_count():
    f=E/'live-notifications.jsonl'
    return len(f.read_text().splitlines()) if f.exists() else 0

def notices_since(n):return [json.loads(l) for l in (E/'live-notifications.jsonl').read_text().splitlines()[n:]] if notice_count()>n else []

try:
    run([HELPER,'provision',SESSION]);provisioned=True
    lab('status','--json')
    shim=R/'shim';shim.mkdir()
    (shim/'herdr').write_text("""#!/usr/bin/env python3
import os,sys,subprocess,json
args=sys.argv[1:];session=os.environ['LIVE_SESSION']
assert args[-2:]==['--session',session],args
p=subprocess.run([os.environ['LIVE_HELPER'],'run',session,*args[:-2]],env={**os.environ,'PATH':os.environ['LIVE_ORIGINAL_PATH']},capture_output=True)
if args[:2]==['notification','show']:
    from pathlib import Path
    q=Path(os.environ['FM_HOME'])/'state/.wake-queue'
    with open(os.environ['LIVE_NOTICE_LOG'],'a') as f:f.write(json.dumps({'args':args,'exit':p.returncode,'reply':p.stdout.decode(),'stderr':p.stderr.decode(),'durable_wake_before_notice':q.read_text() if q.exists() else None})+'\\n')
sys.stdout.buffer.write(p.stdout);sys.stderr.buffer.write(p.stderr);sys.exit(p.returncode)
""")
    (shim/'herdr').chmod(0o755)
    panes=[]
    for name in ['worker','other']:
        pane=json.loads(lab('workspace','create','--cwd',str(R),'--label',name,'--no-focus').stdout)['result']['root_pane']['pane_id'];panes.append(pane)
        lab('pane','run',pane,'sleep 300')
        report(pane,'idle')
    pane=panes[0]
    run([HELPER,'viewer','start',SESSION])
    lab('api','snapshot')

    h=home('states',{'native':pane})
    for state,expected in [('working','working'),('idle','idle'),('blocked','blocked'),('unknown','unknown')]:
        report(pane,state)
        p=run([ROOT/'bin/fm-crew-state.sh','native'],ee=ee(h));assert 'state: '+expected in p.stdout,p.stdout
    report(pane,'unknown')
    proc=start(h);quiet_cycle(h,proc)
    report(pane,'working');quiet_cycle(h,proc)
    report(pane,'idle');quiet_cycle(h,proc)
    report(pane,'blocked');finished(h,proc,'herdr: agent blocked');ack(h)
    n=notice_count();proc=start(h);quiet_cycle(h,proc)
    assert notice_count()==n,'blocked episode repeated notification'
    report(pane,'working');quiet_cycle(h,proc)
    report(pane,'blocked');finished(h,proc,'herdr: agent blocked');ack(h)
    record('PASS native state and blocked episode dedupe','working, idle and unknown stayed quiet; blocked woke once per episode')

    # Keep a stale native working registration while actually killing its process.
    report(pane,'working')
    (h/'state/native.busy-gen').write_text('incarnation-one\n')
    proc=start(h);quiet_cycle(h,proc)
    lab('pane','send-keys',pane,'ctrl+c')
    finished(h,proc,'herdr: agent dead')
    lab('agent','get',pane,check=False)
    lab('pane','process-info','--pane',pane)
    ack(h)
    proc=start(h);quiet_cycle(h,proc)
    lab('pane','close',pane)
    quiet_cycle(h,proc)
    (h/'state/native.busy-gen').write_text('incarnation-two\n')
    finished(h,proc,'herdr: agent missing');ack(h)
    record('PASS death recovery','stale working registration did not hide process death; dead then missing deduped; new incarnation re-armed recovery')

    # A declared wait must not hide endpoint death.
    pane=panes[1];report(pane,'idle')
    hp=home('paused',{'waiter':pane})
    (hp/'state/waiter.status').write_text('paused: waiting for an external dependency\n')
    # Classify the declaration through the public watcher; its initial signal is expected.
    proc=start(hp);finished(hp,proc,'signal:');ack(hp)
    proc=start(hp);quiet_cycle(hp,proc)
    lab('pane','close',pane);finished(hp,proc,'herdr: agent missing');ack(hp)
    record('PASS declared wait recovery','confirmed endpoint absence woke recovery despite paused status')

    # Independent homes make each status batch observable and disposable.
    batches=[
      ('ready',{'a':'done: PR https://github.com/example/project/pull/1 checks green\nworking: routine progress\n'},'Firstmate: review ready'),
      ('ordinary',{'a':'blocked: dependency unavailable\nfailed: build failed\n'},None),
      ('mixed',{'a':'done: PR https://github.com/example/project/pull/2\n','b':'blocked: dependency\nneeds-decision: approve release\n'},'Firstmate: decision needed'),
      ('resolved',{'a':'needs-decision [key=release]: approve release\nresolved [key=release]: approved\nworking: implementation resumed\n'},None),
    ]
    # Real live pane for notification batches, even though signal delivery precedes native polling.
    pane=json.loads(lab('workspace','create','--cwd',str(R),'--label','notices','--no-focus').stdout)['result']['root_pane']['pane_id']
    lab('pane','run',pane,'sleep 300');report(pane,'working')
    for name,events,title in batches:
        h=home('notice-'+name,{task:pane for task in events})
        for task,text in events.items():(h/'state'/f'{task}.status').write_text(text)
        n=notice_count();proc=start(h)
        if name=='resolved':quiet_cycle(h,proc);proc.terminate();proc.wait(12)
        else:finished(h,proc,'signal:')
        sent=notices_since(n);record('Notices for '+name,sent)
        assert len(sent)==(1 if title else 0),sent
        if title:
            assert sent[0]['args'][2]==title and sent[0]['exit']==0 and sent[0]['durable_wake_before_notice'],sent
            assert json.loads(sent[0]['reply'])['result'] is not None,sent
        record('PASS notification '+name,{'expected_title':title,'count':len(sent)})
    lab('api','snapshot')
    record('ALL LIVE SCENARIOS PASSED','')
finally:
    for proc,f in children:
        if proc.poll() is None:
            proc.terminate()
            try:proc.wait(12)
            except subprocess.TimeoutExpired:proc.kill();proc.wait()
        f.close()
    if provisioned:
        result=run([HELPER,'teardown',SESSION],check=False)
        if result.returncode:raise RuntimeError('lab teardown failed')
    for name in ['states','paused','notice-ready','notice-ordinary','notice-mixed','notice-resolved']:
        src=R/name
        if src.exists():
            for f in ['watch.log','state/.watch-triage.log','state/.wake-queue']:
                path=src/f
                if path.exists():shutil.copyfile(path,E/(name+'-'+path.name))
    shutil.rmtree(R)
    log.close()
