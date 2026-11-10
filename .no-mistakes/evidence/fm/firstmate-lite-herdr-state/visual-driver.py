import os, sys, subprocess, time, json, shutil
from pathlib import Path
ROOT=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73T6KEWT536RR3MJ2AYEEYA'); E=Path('/home/runkai/.no-mistakes/evidence/01M73T6KEWT536RR3MJ2AYEEYA'); R=ROOT/'.test-runtime/visual';R.mkdir()
helper=ROOT/'bin/fm-herdr-lab.sh';session='fm-lab-i';env=dict(os.environ)
for key in list(env):
 if key.startswith('HERDR_') or key.endswith('_OVERRIDE') or key=='FM_HOME':env.pop(key,None)
(R/'user-home').mkdir(exist_ok=True)
env.update(HOME=str(R/'user-home'),XDG_DATA_HOME=str(R/'user-home/data'),XDG_CACHE_HOME=str(R/'user-home/cache'),HERDR_CONFIG_PATH=str(E/'h/herdr/lab-config.toml'),XDG_CONFIG_HOME=str(E/'h'),FM_HERDR_LAB_STATE_DIR=str(R/'owner'),TMPDIR=str(ROOT/'.test-runtime'),VIEWER_CAPTURE=str(E/'herdr-viewer.frames.jsonl'))
shim=R/'shim';shim.mkdir()
capture=R/'capture.py'
capture.write_text("""import os,sys,runpy,json,base64,time
actual_read=os.read
output=open(os.environ['VIEWER_CAPTURE'],'a',buffering=1)
def logged_read(fd,n):
 data=actual_read(fd,n)
 output.write(json.dumps({'time':time.time(),'data':base64.b64encode(data).decode()})+'\\n')
 return data
os.read=logged_read
sys.argv=sys.argv[1:]
runpy.run_path(sys.argv[0],run_name='__main__')
""")
(shim/'python3').write_text('#!/usr/bin/env bash\nif [[ "${1:-}" == */fm-herdr-lab-viewer.py ]]; then exec '+sys.executable+' '+str(capture)+' "$@"; fi\nexec '+sys.executable+' "$@"\n');(shim/'python3').chmod(0o755)
env['PATH']=str(shim)+':'+env['PATH']
log=open(E/'visual-product.log','w',buffering=1)
def run(*a):
 p=subprocess.run([str(x) for x in a],env=env,cwd=ROOT,capture_output=True,text=True,timeout=30)
 log.write('$ '+' '.join(str(x) for x in a)+'\n'+p.stdout+p.stderr+'\n');log.flush()
 if p.returncode:raise RuntimeError(p.stdout+p.stderr)
 return p.stdout
try:
 run(helper,'provision',session)
 w=json.loads(run(helper,'run',session,'workspace','create','--cwd',R,'--label','notification-proof','--no-focus'));pane=w['result']['root_pane']['pane_id']
 run(helper,'viewer','start',session)
 run(helper,'run',session,'pane','run',pane,"printf 'Live Herdr notification verification\\n'")
 time.sleep(.7)
 for title,body,sound in [('Firstmate: review ready','review-task','done'),('Firstmate: decision needed','release-task','request')]:
  result=run(helper,'run',session,'notification','show',title,'--body',body,'--sound',sound)
  assert json.loads(result)['result']['shown'] is True
  time.sleep(6)
finally:
 run(helper,'teardown',session)
 shutil.rmtree(R)
 log.close()
import runpy
runpy.run_path(str(E/'render-viewer.py'),run_name='__main__')
