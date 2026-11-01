from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT')
exec((E/'live-friction.py').read_text().split("run(['bin/fm-lab-home.sh'")[0].replace("'w',buffering=1", "'a',buffering=1"))
state=json.loads((E/'live-state.json').read_text());W=Path(state['copy']);ID=state['id'];env['TMUX']=state['socket']+',0,0'
env['CHROME_DEVTOOLS_AXI_SESSION']='fm-lab-friction'
print(run(['chrome-devtools-axi','stop'],good=None))
env['CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH']=str(L/'browser/chrome/linux-156.0.8078.80/chrome-linux64/chrome')
env['CHROME_DEVTOOLS_AXI_CHROME_ARGS']='--no-sandbox --disable-dev-shm-usage'
print(run(['chrome-devtools-axi','start'],cwd=W,good=None))
