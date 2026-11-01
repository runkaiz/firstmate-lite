from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round2')
exec((E/'browser-start.py').read_text().split("print(run(")[0])
log.close();log=open(E/'browser-guards.log','w',buffering=1)
K=H/'data'/ID/'preserved-artifacts';meta=H/'state'/f'{ID}.meta'
names=['--preserve-untracked','web','--preserve-untracked','.cache','--preserve-untracked','build','--preserve-untracked','scripts']
def td(*args,good=1):return run([R/'bin/fm-teardown.sh',ID,*args],good=good)
def intact(): assert W.exists() and meta.exists() and not (K/'files').exists()
rec=L/'user/.chrome-devtools-axi/sessions/fm-lab-friction-round2/bridge.pid'
run(['chrome-devtools-axi','stop'],cwd=W)
run(['chrome-devtools-axi','stop'],cwd=L,extra={'CHROME_DEVTOOLS_AXI_SESSION':'fm-lab-unrelated-round2'})
env['TMPDIR']='/tmp' # Incidental browser temp sockets need short Unix paths.
chrome_log=open(E/'external-chrome.log','w')
chrome=subprocess.Popen([env['CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH'],'--headless','--no-sandbox','--disable-dev-shm-usage','--remote-debugging-port=19442','--user-data-dir='+str(L/'external-profile'),'about:blank'],cwd=L,env=env,stdout=chrome_log,stderr=subprocess.STDOUT)
(E/'external-chrome-pid.txt').write_text(str(chrome.pid))
import urllib.request
for i in range(100):
    try:
        with urllib.request.urlopen('http://127.0.0.1:19442/json/version',timeout=1) as response: json.load(response)
        break
    except Exception: time.sleep(.1)
else: raise AssertionError('Chrome not ready')
env['CHROME_DEVTOOLS_AXI_BROWSER_URL']='http://127.0.0.1:19442'
run(['chrome-devtools-axi','start'],cwd=W)
original=rec.read_text();bridge=json.loads(original)['pid']
run(['chrome-devtools-axi','start'],cwd=L,extra={'CHROME_DEVTOOLS_AXI_SESSION':'fm-lab-unrelated-round2'})
otherrec=L/'user/.chrome-devtools-axi/sessions/fm-lab-unrelated-round2/bridge.pid'
other=json.loads(otherrec.read_text())['pid']
rec.write_text(json.dumps({'pid':99999999,'port':9908}))
try:
    out=td(*names);assert 'not proven task-owned' in out;os.kill(bridge,0);intact()
finally:rec.write_text(original)
log.write('PASS: mismatched record refuses cleanup and leaves bridge alive.\n')
extra=subprocess.Popen(['sleep','300'],cwd=W,env=env)
try:
    out=td(*names);assert 'beside other process' in out;os.kill(bridge,0);assert extra.poll() is None;intact()
finally:extra.terminate();extra.wait()
log.write('PASS: unrelated copy process refuses cleanup and leaves both processes alive.\n')
expected={str(p.relative_to(W)):hashlib.sha256(p.read_bytes()).hexdigest() for root in ['.cache','build','web','scripts'] for p in (W/root).rglob('*') if p.is_file() and str(p.relative_to(W)) not in ['web/package.json','scripts/run.py']}
out=td(*names,good=0)
assert 'stopping task-owned chrome-devtools-axi bridge' in out
assert not W.exists() and not meta.exists()
actual={str(p.relative_to(K/'files')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (K/'files').rglob('*') if p.is_file()}
assert expected==actual and len(actual)==16735
assert not rec.exists();os.kill(other,0)
shutil.copy(K/'receipt',E/'preservation-receipt.txt')
log.write('PASS: parent names preserve all 16,735 file hashes, exclude tracked files, remove task copy and records, stop the task bridge, leave the unrelated session alive.\n')
run(['chrome-devtools-axi','stop'],cwd=L,extra={'CHROME_DEVTOOLS_AXI_SESSION':'fm-lab-unrelated-round2'})
print('Ownership guards, bridge shutdown and parent preservation passed.')

chrome.terminate();chrome.wait(timeout=20)
