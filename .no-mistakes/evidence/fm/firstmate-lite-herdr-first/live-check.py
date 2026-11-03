import os, subprocess, pathlib, time, json, shutil, shlex
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6GGMMMF21GAXJG1J6XGCMTC')
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M6GGMMMF21GAXJG1J6XGCMTC')
W=ROOT/'.gate-live'
log=(E/'product-transcript.log').open('w')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ('TMUX','TMUX_PANE'):
        env.pop(k,None)
env['TMPDIR']=str(W)
home=W/'home'
def run(args, extra=None, check=True, timeout=100):
    e=env.copy(); e.update(extra or {})
    log.write('$ '+shlex.join(map(str,args))+'\n'); log.flush()
    p=subprocess.run(list(map(str,args)),env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log.write(p.stdout+f'[exit {p.returncode}]\n'); log.flush()
    if check and p.returncode: raise RuntimeError(p.stdout[-2500:])
    return p
results=[]
def done(name):
    results.append(name); print('PASS '+name,flush=True)
    (E/'passed-live-checks.json').write_text(json.dumps(results,indent=2))
run(['bin/fm-lab-home.sh','create',home])
env['FM_HOME']=str(home)
# The actual backend resolver executes with real installed tools, no runtime doubles.
def select(expected,extra=None):
    p=run(['bash','-c','. bin/fm-backend.sh; fm_backend_name'],extra)
    assert p.stdout==expected,(p.stdout,expected)
select('herdr')
select('tmux',{'PATH':'/usr/bin:/bin'})
(home/'config/backend').write_text('tmux\n')
select('tmux')
select('herdr',{'FM_BACKEND':'herdr'})
(home/'config/backend').unlink()
done('Installed Herdr is the default; absent Herdr falls back to tmux; config and environment overrides win')
proj=W/'project'; proj.mkdir()
run(['git','-C',proj,'init','-q','-b','main'])
(proj/'README.md').write_text('Disposable live validation project.\n')
run(['git','-C',proj,'add','README.md'])
run(['git','-C',proj,'-c','user.name=Live Test','-c','user.email=live@example.invalid','commit','-qm','initial'])
(home/'config/worktree-allocator').write_text('git\n')
(home/'config/git-worktree-root').write_text(str(W/'copies')+'\n')
(home/'data/projects.md').write_text('# Projects\n\n- project [local-only] - disposable fixture\n')
run(['bin/fm-brief.sh','liveworker','project','--mode','local-only','--project',proj])
brief=home/'data/liveworker/brief.md'
s=brief.read_text().replace('{TASK}','Demonstrate a running worker in an isolated terminal.').replace('{FIRSTMATE_SPEC}','Print a readiness marker and wait for teardown.')
brief.write_text(s)
# Removed selections must refuse before acquiring a worktree or endpoint.
for backend in ('zellij','cmux','orca'):
    p=run(['bin/fm-spawn.sh','liveworker',proj,"sh -c 'echo should-not-launch'",'--mode','local-only','--yolo','off','--backend',backend],check=False)
    assert p.returncode and 'removed from Firstmate' in p.stdout and 'herdr' in p.stdout and 'tmux' in p.stdout,p.stdout
    assert not (home/'state/liveworker.meta').exists()
    assert not (W/'copies').exists()
    (home/'config/backend').write_text(backend+'\n')
    p=run(['bin/fm-bootstrap.sh'],{'FM_BOOTSTRAP_DETECT_ONLY':'1','FM_BOOTSTRAP_NETWORK':'skip'},timeout=150)
    assert f'BACKEND_INVALID: {backend} (removed;' in p.stdout,p.stdout
(home/'config/backend').unlink()
done('Removed Zellij, cmux, and Orca selections fail before worker allocation and bootstrap gives a migration instruction')
# Prove the mandatory Herdr lab cannot be provisioned under isolated XDG state.
lab='fm-lab-gate-'+str(os.getpid())
p=run(['bin/fm-herdr-lab.sh','prepare',lab],{'XDG_CONFIG_HOME':str(W/'xdg-config'),'FM_HERDR_LAB_STATE_DIR':str(W/'lab-state')},check=False)
assert p.returncode!=0 and 'tripwire requires exactly one running default session' in p.stdout,p.stdout
# tmux: explicit private socket; every backend subprocess inherits its actual TMUX identity.
socket=ROOT/'.t'
try:
    run(['tmux','-S',socket,'new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'bash --noprofile --norc'])
    tmuxid=run(['tmux','-S',socket,'display-message','-p','-t','primary','#{socket_path},#{pid},0']).stdout.strip()
    env['TMUX']=tmuxid
    select('tmux')
    # Simultaneous Herdr environment and actual tmux pane proves innermost tmux wins.
    select('tmux',{'HERDR_ENV':'1'})
    done('Running on a private tmux server selects tmux even when Herdr is installed or an outer Herdr marker is inherited')
    launch="sh -c 'printf \"live-worker-%s\\n\" ready'"
    p=run(['bin/fm-spawn.sh','liveworker',proj,launch,'--mode','local-only','--yolo','off'],{'FM_SPAWN_NO_GUARD':'1'},timeout=150)
    meta=home/'state/liveworker.meta'
    assert meta.exists(),p.stdout
    fields=dict(line.split('=',1) for line in meta.read_text().splitlines() if '=' in line)
    log.write('PERSISTED METADATA\n'+meta.read_text()+'\n'); log.flush()
    assert fields.get('backend','tmux')=='tmux'
    target=fields['window']
    for i in range(40):
        p=run(['bin/fm-peek.sh','liveworker','100'])
        if 'live-worker-ready' in p.stdout: break
        time.sleep(.25)
    assert 'live-worker-ready' in p.stdout,p.stdout
    # Durable steering is the supported normal text surface.
    p=run(['bin/fm-send.sh','liveworker','Please retain this disposable live-check instruction.'])
    inbox=list((home/'state/liveworker.inbox').glob('*.md'))
    if not inbox: inbox=[p for p in (home/'state/liveworker.inbox').iterdir() if p.is_file()]
    assert any('Please retain this disposable live-check instruction.' in p.read_text() for p in inbox),inbox
    for f in inbox:
        log.write('DURABLE INBOX '+f.name+'\n'+f.read_text()+'\n')
    log.flush()
    run(['bin/fm-teardown.sh','liveworker'],timeout=150)
    assert not meta.exists()
    assert not pathlib.Path(fields['worktree']).exists()
    p=run(['tmux','-S',socket,'list-windows','-t','primary','-F','#{window_name}'])
    assert 'fm-liveworker' not in p.stdout
    done('A tmux fallback worker spawns, executes, exposes captured output, accepts durable steering, and tears down its endpoint and copy')
finally:
    run(['tmux','-S',socket,'kill-server'],check=False)
    socket.unlink(missing_ok=True)
log.close()
