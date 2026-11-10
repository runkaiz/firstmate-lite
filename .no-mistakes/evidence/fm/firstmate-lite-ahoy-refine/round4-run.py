import os,pathlib,shutil,subprocess,traceback
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
L=R/'.l'; T=R/'.ahoy-validation-tmp'
assert not L.exists() and not T.exists()
T.mkdir()
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','NO_MISTAKES_','GIT_','TMUX'))}
env.update(TMPDIR=str(T),GIT_CEILING_DIRECTORIES=str(R),FM_HOME=str(L),TMUX_TMPDIR=str(L/'tmux'))
try:
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(L)],cwd=R,env=env,check=True)
    (L/'tmux').mkdir()
    for file in ['round4-cli-driver.py','round4-chat-driver.py','round4-actionable-driver.py']:
        subprocess.run(['python3',str(E/file)],cwd=R,env=env,check=True)
finally:
    subprocess.run(['tmux','-L','fm-lab','kill-server'],cwd=R,env=env,capture_output=True)
    shutil.rmtree(L,ignore_errors=True)
    shutil.rmtree(T,ignore_errors=True)
    print('Disposable lab, private tmux server, and temporary data removed.',flush=True)
