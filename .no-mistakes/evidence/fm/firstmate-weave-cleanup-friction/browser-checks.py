from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT')
exec((E/'browser-live.py').read_text().split("print(run(['chrome-devtools-axi','stop']")[0])
env['CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH']=str(L/'browser/chrome/linux-156.0.8078.80/chrome-linux64/chrome')
env['CHROME_DEVTOOLS_AXI_CHROME_ARGS']='--no-sandbox --disable-dev-shm-usage'
env['CHROME_DEVTOOLS_AXI_BROWSER_URL']='http://127.0.0.1:19441'
K=H/'data'/ID/'preserved-artifacts';meta=H/'state'/f'{ID}.meta'
def td(*args,good=1):return run([R/'bin/fm-teardown.sh',ID,*args],good=good)
names=['--preserve-untracked', 'web','--preserve-untracked','.cache','--preserve-untracked','build','--preserve-untracked','scripts']
def intact(): assert W.exists() and meta.exists() and not (K/'files').exists()
rec=L/'user/.chrome-devtools-axi/sessions/fm-lab-friction/bridge.pid'
original=rec.read_text();bridge=json.loads(original)['pid']
run(['ps','-p',str(bridge),'-o','pid,ppid,pgid,args'])
run(['chrome-devtools-axi','open','data:text/html,<title>Task helper</title><h1>Isolated cleanup lab</h1>'],cwd=W)
run(['chrome-devtools-axi','start'],cwd=L,extra={'CHROME_DEVTOOLS_AXI_SESSION':'fm-lab-unrelated'})
otherrec=L/'user/.chrome-devtools-axi/sessions/fm-lab-unrelated/bridge.pid'
other=json.loads(otherrec.read_text())['pid']
rec.write_text(json.dumps({'pid':99999999,'port':9908}))
try:
    out=td(*names);assert 'not proven task-owned' in out;os.kill(bridge,0);intact()
finally:rec.write_text(original)
log.write('VERIFIED: a real browser bridge with a mismatched session record is not stopped.\n')
extra=subprocess.Popen(['sleep','300'],cwd=W,env=env)
try:
    out=td(*names);assert 'beside other process' in out;os.kill(bridge,0);assert extra.poll() is None;intact()
finally:extra.terminate();extra.wait()
log.write('VERIFIED: unrelated process beside the bridge refuses cleanup and leaves both processes alive.\n')
expected={str(p.relative_to(W)):hashlib.sha256(p.read_bytes()).hexdigest() for root in ['.cache','build','web','scripts'] for p in (W/root).rglob('*') if p.is_file() and str(p.relative_to(W)) not in ['web/package.json','scripts/run.py']}
out=td(*names,good=0)
assert 'stopping task-owned chrome-devtools-axi bridge' in out
assert not W.exists() and not meta.exists()
actual={str(p.relative_to(K/'files')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (K/'files').rglob('*') if p.is_file()}
assert expected==actual and len(actual)==16735
assert not rec.exists();os.kill(other,0)
shutil.copy(K/'receipt',E/'preservation-receipt.txt')
log.write('VERIFIED: 16,735 file hashes match preserved artifacts; tracked files excluded; task copy and records removed; unrelated session still alive.\n')
run(['chrome-devtools-axi','stop'],cwd=L,extra={'CHROME_DEVTOOLS_AXI_SESSION':'fm-lab-unrelated'})
print('Real browser ownership guards, parent-folder preservation, and isolated helper shutdown passed.')
