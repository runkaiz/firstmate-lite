from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round3')
exec((E/'browser-start.py').read_text().split("print(run(")[0])
log.close();log=open(E/'browser-regression.log','a',buffering=1)
K=H/'data'/ID/'preserved-artifacts';meta=H/'state'/f'{ID}.meta'
names=['--preserve-untracked','web','--preserve-untracked','.cache','--preserve-untracked','build','--preserve-untracked','scripts']
def td(*args,good=1):return run([R/'bin/fm-teardown.sh',ID,*args],good=good)
def intact(): assert W.exists() and meta.exists() and not (K/'files').exists()
rec=L/'user/.chrome-devtools-axi/sessions/fm-lab-friction-round3/bridge.pid'
log.write('SETUP RETRY: driver deadline increased from 120s to 600s because real lsof scans take roughly ten seconds per scan on this host; product uses twenty bounded scans.\n')
run(['chrome-devtools-axi','open','data:text/html,<title>Cleanup lab</title><h1>Task-owned browser</h1>'],cwd=W)
bridge=json.loads(rec.read_text())['pid']
otherrec=L/'user/.chrome-devtools-axi/sessions/fm-lab-unrelated-round3/bridge.pid'
other=json.loads(otherrec.read_text())['pid']
extra=subprocess.Popen(['sleep','300'],cwd=W,env=env)
try:
    out=td(*names)
    assert 'stopping task-owned chrome-devtools-axi bridge' in out
    assert 'copy processes remain after stopping its chrome-devtools-axi bridge: '+str(extra.pid) in out
    assert extra.poll() is None and not rec.exists();intact();os.kill(other,0)
    try: os.kill(bridge,0)
    except ProcessLookupError: pass
    else: raise AssertionError('Owned bridge remains alive')
finally:extra.terminate();extra.wait()
log.write('PASS: tool stops the proven real browser bridge and Chrome; cleanup refuses with the unrelated surviving pid and moves no files.\n')
run(['chrome-devtools-axi','open','data:text/html,<title>Cleanup lab</title><h1>Task-owned browser</h1>'],cwd=W)
bridge=json.loads(rec.read_text())['pid']
expected={str(p.relative_to(W)):hashlib.sha256(p.read_bytes()).hexdigest() for root in ['.cache','build','web','scripts'] for p in (W/root).rglob('*') if p.is_file() and str(p.relative_to(W)) not in ['web/package.json','scripts/run.py']}
out=td(*names,good=0)
assert 'stopping task-owned chrome-devtools-axi bridge' in out
assert not W.exists() and not meta.exists()
actual={str(p.relative_to(K/'files')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (K/'files').rglob('*') if p.is_file()}
assert expected==actual and len(actual)==16735
assert not rec.exists();os.kill(other,0)
shutil.copy(K/'receipt',E/'preservation-receipt.txt')
log.write('PASS: task-owned local Chrome stops automatically; parent names preserve all 16,735 file hashes, exclude tracked files, remove task copy and records, and leave the unrelated browser session alive.\n')
run(['chrome-devtools-axi','stop'],cwd=L,extra={'CHROME_DEVTOOLS_AXI_SESSION':'fm-lab-unrelated-round3'})
print('Local Chrome cleanup, mismatched and duplicate records, unrelated-process guard, and byte-exact parent preservation passed.')
