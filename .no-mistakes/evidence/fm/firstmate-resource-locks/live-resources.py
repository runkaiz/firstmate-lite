import os, pathlib, subprocess, tempfile, time, signal, shutil, json

ROOT = pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ')
EVIDENCE = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E5G3VE4WRF2AH7TSMB9MDJ')
CASE = pathlib.Path(tempfile.mkdtemp(prefix='live resources ', dir=ROOT / '.validation-tmp'))
HOME = CASE / 'home'
(HOME / 'config').mkdir(parents=True)
(HOME / 'data').mkdir()
RUNTIME = CASE / 'runtime'
RUNTIME.mkdir()
DECL = HOME / 'config/resource-locks'
DECL.write_text('suite 2 22:00-09:00=1 full test suites\ngpu 1 GPU commands\n')
ENV = {k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
ENV.update(FM_HOME=str(HOME), XDG_RUNTIME_DIR=str(RUNTIME), FM_RESOURCE_LOCK_NOW='23:00', FM_RESOURCE_LOCK_POLL_SECS='0.05')
LOCK = str(ROOT / 'bin/fm-resource-lock.sh')
processes = []
logs = []
def note(text):
    print(text, flush=True)
def run(args, env=ENV):
    p = subprocess.run([str(a) for a in args], env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    note('$ ' + ' '.join(map(str,args)))
    note(p.stdout.rstrip() + '\nexit=' + str(p.returncode))
    return p
def spawn(args, tag, env=ENV):
    log = CASE / (tag+'.log')
    out = log.open('w')
    p = subprocess.Popen([str(a) for a in args], env=env, stdout=out, stderr=subprocess.STDOUT, start_new_session=True)
    out.close()
    processes.append(p)
    logs.append(log)
    return p
def await_(predicate, message):
    deadline = time.monotonic()+12
    while not predicate():
        if time.monotonic()>deadline: raise AssertionError(message)
        time.sleep(.05)
def waiting(tag):
    return 'waiting for' in (CASE/(tag+'.log')).read_text()
try:
    note('REAL PRODUCT: command wrappers, inherited locks, child processes, and generated worker instructions')
    for kind, flags in [('ship', ['--mode','local-only']), ('scout', ['--scout'])]:
        p = run([ROOT/'bin/fm-brief.sh', 'proof-'+kind, 'demo', *flags])
        assert p.returncode == 0
        brief = (HOME/'data'/('proof-'+kind)/'brief.md').read_text()
        (EVIDENCE/('generated-'+kind+'-brief.md')).write_text(brief)
        line = next(x for x in brief.splitlines() if x.startswith('- `gpu`'))
        wrapper = line.rsplit(': `',1)[1].removesuffix('`').replace('<command>', "sh -c 'printf \"brief-wrapper-executed\\n\"; exit 7'")
        childenv = dict(ENV)
        childenv.pop('FM_HOME',None)
        p = run(['bash','-c','cd /; '+wrapper], childenv)
        assert p.returncode == 7 and 'brief-wrapper-executed' in p.stdout
    note('Observed: both generated wrappers run from / without FM_HOME, including shell-escaped declaration paths with spaces.')

    childhome=CASE/'child-home'
    (childhome/'config').mkdir(parents=True)
    (childhome/'config/resource-locks').write_text('gpu 9 child must not override the root limit\n')
    (childhome/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(HOME)+'\n')
    childenv=dict(ENV,FM_HOME=str(childhome))
    p=run([LOCK,'brief'],childenv)
    assert p.returncode==0 and '`gpu` (1 at once)' in p.stdout
    marker=CASE/'root-holder'
    release_root=CASE/'root-release'
    root_holder=spawn([LOCK,'run','gpu','--','sh','-c',': > "$1"; while [ ! -e "$2" ]; do sleep .1; done','_',marker,release_root],'root-holder')
    await_(marker.exists,'root holder did not start')
    child_marker=CASE/'child-home-ran'
    child_job=spawn([LOCK,'run','gpu','--','touch',child_marker],'child-home',childenv)
    await_(lambda:waiting('child-home'),'child home ignored the root GPU holder')
    assert not child_marker.exists()
    release_root.touch()
    assert root_holder.wait(8)==0 and child_job.wait(8)==0 and child_marker.exists()
    note('Observed: a locally linked home uses the root declaration and waits for the root home GPU holder despite its own gpu=9 declaration.')

    nested = CASE/'nested-held'
    release = CASE/'release-nested'
    holder = spawn([LOCK,'run','suite','--',LOCK,'run','gpu','--','sh','-c',
        ': > "$1"; while [ ! -e "$2" ]; do sleep .1; done', '_',nested,release], 'nested')
    await_(nested.exists, 'nested command never acquired its resources')
    for name in ['suite','gpu']:
        spawn([LOCK,'run',name,'--','touch',CASE/(name+'-ran')],name)
        await_(lambda n=name:waiting(n),'competitor did not wait')
    time.sleep(1.1)
    assert not (CASE/'suite-ran').exists() and not (CASE/'gpu-ran').exists()
    note('Observed: nested suite -> gpu command is running; independent suite and gpu competitors both remain blocked.')
    release.touch()
    assert holder.wait(5)==0
    await_(lambda:(CASE/'suite-ran').exists() and (CASE/'gpu-ran').exists(),'competitors never entered after release')
    note('Observed: nested command exited; both competitors then ran.')

    child = CASE/'child-held'
    child_release = CASE/'release-child'
    child_ran = CASE/'after-child'
    parent = spawn([LOCK,'run','gpu','--','sh','-c',
        '( : > "$1"; while [ ! -e "$2" ]; do sleep .1; done ) & exit 13','_',child,child_release], 'parent')
    await_(child.exists,'descendant did not start')
    assert parent.wait(5)==13
    waiter=spawn([LOCK,'run','gpu','--','touch',child_ran],'descendant-waiter')
    await_(lambda:waiting('descendant-waiter'),'waiter did not wait for child')
    assert not child_ran.exists()
    note('Observed: parent exited with status 13; its running descendant still prevents GPU admission.')
    child_release.touch()
    assert waiter.wait(8)==0 and child_ran.exists()
    note('Observed: descendant exited; GPU competitor then ran.')

    for declaration in ['suite 2 22:00-09:00=0 forbidden zero window\n','suite 1 valid\nsuite 2 duplicate\n']:
        DECL.write_text(declaration)
        p=run([LOCK,'run','suite','--','touch',CASE/'must-not-run'])
        assert p.returncode==1 and not (CASE/'must-not-run').exists()
        p=run([ROOT/'bin/fm-brief.sh','invalid','demo','--scout'])
        assert p.returncode==1 and not (HOME/'data/invalid').exists()
    note('Observed: invalid declarations execute no payload and leave no partial worker instructions.')
    p=run([LOCK,'list'])
    assert p.returncode==2
    note('Observed: removed list interface is rejected with exit 2.')
    note('All manual resource scenarios passed.')
finally:
    for p in processes:
        try: os.killpg(p.pid,signal.SIGTERM)
        except ProcessLookupError: pass
    for p in processes:
        try: p.wait(timeout=3)
        except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL)
    for log in logs:
        note('\nPRODUCT STDERR '+log.name+'\n'+log.read_text())
    shutil.rmtree(CASE)
    note('Removed disposable homes, runtime locks, and child processes.')
