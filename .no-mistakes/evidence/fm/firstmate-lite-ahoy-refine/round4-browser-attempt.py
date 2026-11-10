import os,pathlib,subprocess
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
env=os.environ.copy()
for key in list(env):
    if key.startswith('CHROME_DEVTOOLS_AXI_') and key not in ('CHROME_DEVTOOLS_AXI_MCP_PATH',): env.pop(key)
for name,folder in [('XDG_CONFIG_HOME','config'),('XDG_STATE_HOME','state'),('XDG_CACHE_HOME','cache'),('XDG_RUNTIME_DIR','runtime')]:
    path=R/'.ahoy-browser'/folder;path.mkdir(parents=True,exist_ok=True);env[name]=str(path)
env.update(CHROME_DEVTOOLS_AXI_SESSION='nm-ahoy-round4',CHROME_DEVTOOLS_AXI_USER_DATA_DIR=str(R/'.ahoy-browser/profile'),CHROME_DEVTOOLS_AXI_BRIDGE_TIMEOUT_MS='10000',CHROME_DEVTOOLS_AXI_IDLE_TIMEOUT_MS='20000')
log=[]
try:
    for args in [('open',(E/'round4-ahoy-live-replies.html').as_uri()+'#quiet'),('screenshot',str(E/'round4-ahoy-quiet.png'))]:
        try:
            p=subprocess.run(['chrome-devtools-axi',*args],env=env,cwd=R,text=True,capture_output=True,timeout=25)
            log.append('$ chrome-devtools-axi '+' '.join(args)+'\n'+p.stdout+p.stderr)
            if p.returncode:break
        except subprocess.TimeoutExpired:
            log.append('Browser command exceeded 25-second deadline.');break
finally:
    try:
        p=subprocess.run(['chrome-devtools-axi','stop'],env=env,cwd=R,text=True,capture_output=True,timeout=20)
        log.append(p.stdout+p.stderr)
    except subprocess.TimeoutExpired:log.append('Stop exceeded deadline; bridge idle timeout is configured.')
    (E/'round4-browser-capture-attempt.txt').write_text('\n'.join(log))
print('\n'.join(log))

import shutil
shutil.rmtree(R/'.ahoy-browser',ignore_errors=True)
