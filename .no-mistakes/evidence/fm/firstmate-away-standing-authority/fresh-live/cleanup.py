from pathlib import Path
import os, subprocess, time, json, shutil
root=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E4EMMHJV5XTAZSM4MWEZTN')
lab=root/'.l'
ev=Path('/home/runkai/.no-mistakes/evidence/01M7E4EMMHJV5XTAZSM4MWEZTN/fresh-live')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','NO_MISTAKES_GATE','TMUX','CLAUDECODE')}
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),TMPDIR=str(root/'.lv'))
def tmux(*args):
    return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
log=[]
record=lab/'state/.supervision-host'
if record.exists():
    rows=[s.split('\t') for s in record.read_text().splitlines()]
    pid=next(r[1] for r in rows if r[0]=='host')
    assert pid.isdigit()
    p=tmux('run-shell','-t','primary:0','kill -TERM '+pid)
    log.append('Stopped only recorded lab host through private socket: '+str(p.returncode)+' '+p.stdout)
    end=time.time()+25
    while record.exists() and time.time()<end: time.sleep(.2)
    assert not record.exists(), 'Lab host did not finish its cleanup'
    log.append('Host record retired; engine and watcher cleanup completed.')
for name in ('primary-result.json','primary-errors.log'):
    p=lab/name
    if p.exists(): shutil.copyfile(p,ev/name)
p=tmux('kill-server')
log.append('Killed only fm-lab server on lab private socket: '+str(p.returncode)+' '+p.stdout)
assert p.returncode==0
p=tmux('list-sessions')
assert p.returncode!=0
log.append('Private server is no longer running: '+p.stdout.strip())
for name in ('setup.py','drive.py','check.py','cleanup.py','primary.sh','launch.sh'):
    shutil.copyfile(root/'.lv'/name,ev/name)
(ev/'teardown.txt').write_text('\n'.join(log)+'\n')
print('\n'.join(log))
