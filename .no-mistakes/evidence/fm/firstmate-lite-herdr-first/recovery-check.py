import os, pathlib, subprocess, shlex, json
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6GGMMMF21GAXJG1J6XGCMTC')
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M6GGMMMF21GAXJG1J6XGCMTC')
home=ROOT/'.gate-live/recovery'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k.startswith('HERDR_') or k in ('TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(home),FM_BOOTSTRAP_NETWORK='skip',TMPDIR=str(ROOT/'.gate-live'))
log=(E/'recovery-transcript.log').open('w')
def run(args,ok=True):
    log.write('$ '+shlex.join(map(str,args))+'\n'); log.flush()
    p=subprocess.run(list(map(str,args)),env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    log.write(p.stdout+f'[exit {p.returncode}]\n'); log.flush()
    if ok: assert p.returncode==0,p.stdout
    return p
run(['bin/fm-lab-home.sh','create',home])
(home/'config/backend').write_text('tmux\n')
(home/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
for kind in ('ship','scout'):
    (home/f'state/recovery-{kind}.meta').write_text(f'kind={kind}\ncleanup_recovery=orca\n')
(home/'data').rename(home/'data-held')
p=run(['bin/fm-bootstrap.sh'])
assert 'bootstrap cannot access configured backlog' not in p.stdout
print('PASS Recovery-only home starts without backlog storage',flush=True)
(home/'data-held').rename(home/'data')
backlog=home/'data/backlog.md'
backlog.write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
for kind in ('ship','scout'):
    run(['bin/fm-queue.py','add','recovery-'+kind,'failed '+kind+' launch','--kind',kind,'--file',backlog])
run(['bin/fm-queue.py','add','ordinary-ship','successfully launched worker','--kind','ship','--file',backlog])
(home/'state/ordinary-ship.meta').write_text('kind=ship\n')
run(['bin/fm-bootstrap.sh'])
for kind in ('ship','scout'):
    p=run(['bin/fm-queue.py','show','recovery-'+kind,'--file',backlog])
    assert 'state: queued' in p.stdout,p.stdout
    assert (home/f'state/recovery-{kind}.meta').exists()
p=run(['bin/fm-queue.py','show','ordinary-ship','--file',backlog])
assert 'state: in_flight' in p.stdout,p.stdout
log.write('PERSISTED BACKLOG CONTRACT\n'+backlog.read_text())
log.close()
print('PASS Bootstrap keeps failed ship/scout recovery queued while moving an ordinary worker to In flight',flush=True)
