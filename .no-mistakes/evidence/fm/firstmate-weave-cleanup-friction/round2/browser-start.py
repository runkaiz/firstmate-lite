from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round2')
exec((E/'live-friction.py').read_text().split("run(['bin/fm-lab-home.sh'")[0].replace("'w',buffering=1", "'a',buffering=1"))
state=json.loads((E/'live-state.json').read_text());W=Path(state['copy']);ID=state['id'];env['TMUX']=state['socket']+',0,0'
env.update(CHROME_DEVTOOLS_AXI_SESSION='fm-lab-friction-round2',CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH=str(L/'browser/chrome/linux-156.0.8078.80/chrome-linux64/chrome'),CHROME_DEVTOOLS_AXI_CHROME_ARGS='--no-sandbox --disable-dev-shm-usage',CHROME_DEVTOOLS_AXI_MCP_PATH=str(L/'deps/node_modules/chrome-devtools-mcp/build/src/bin/chrome-devtools-mcp.js'))
print(run(['chrome-devtools-axi','open','data:text/html,<title>Cleanup lab</title><h1>Task-owned browser</h1>'],cwd=W,good=None))
