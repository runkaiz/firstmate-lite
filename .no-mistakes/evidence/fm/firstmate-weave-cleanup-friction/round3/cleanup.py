import os,subprocess,time,shutil
from pathlib import Path
R=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6AHC9AFYM09CJWRZYXBSTTT');L=R/'.lv3'
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round3')
with (E/'cleanup.log').open('w') as log:
    x=subprocess.run(['tmux','-S',str(L/'s'),'kill-server'],capture_output=True,text=True)
    log.write('Private tmux server stopped: exit '+str(x.returncode)+'\n')
    time.sleep(1)
    root=L.resolve()
    remaining=[]
    for row in subprocess.check_output(['ps','-eo','pid='],text=True).splitlines():
        pid=int(row)
        try:
            cwd=Path('/proc',str(pid),'cwd').resolve(strict=True)
            if cwd==root or root in cwd.parents:remaining.append(pid)
        except (OSError,RuntimeError):pass
    log.write('Processes with cwd in disposable workspace: '+str(remaining)+'\n')
    assert not remaining,remaining
    shutil.rmtree(L)
    log.write('Removed disposable homes, project, native copies, npm dependencies and Chrome download.\n')
print('Disposable resources removed.')
