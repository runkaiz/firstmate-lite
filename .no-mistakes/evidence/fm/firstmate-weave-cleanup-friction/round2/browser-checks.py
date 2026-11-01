from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round2')
exec((E/'browser-start.py').read_text().split("print(run(")[0])
log.close();log=open(E/'browser-regression.log','w',buffering=1)
K=H/'data'/ID/'preserved-artifacts';meta=H/'state'/f'{ID}.meta'
names=['--preserve-untracked','web','--preserve-untracked','.cache','--preserve-untracked','build','--preserve-untracked','scripts']
def td(*args,good=1):return run([R/'bin/fm-teardown.sh',ID,*args],good=good)
def intact(): assert W.exists() and meta.exists() and not (K/'files').exists()
rec=L/'user/.chrome-devtools-axi/sessions/fm-lab-friction-round2/bridge.pid'
bridge=json.loads(rec.read_text())['pid']
run(['ps','-p',bridge,'-o','pid,ppid,pgid,sid,args'])
rows=subprocess.check_output(['ps','-eo','pid,ppid,pgid,sid,comm'],text=True).splitlines()[1:]
for row in rows:
    try:
        if Path('/proc',row.split()[0],'cwd').resolve()==W.resolve():
            log.write('COPY PROCESS: '+row+'\n')
            if 'chrome_crashpad' in row:
                _,ppid,pgid,sid,_=row.split(maxsplit=4)
                run(['ps','-p',pgid+','+sid,'-o','pid,ppid,pgid,sid,args'],good=None)
    except (OSError,RuntimeError): pass
out=td(*names,good=None)
failed='beside other process' in out
(E/'browser-result.json').write_text(json.dumps({'local_browser_cleanup':'fail' if failed else 'pass','bridge_pid':bridge}))
if failed:
    intact();os.kill(bridge,0)
    log.write('FAIL: valid task-owned local browser still blocks automatic cleanup.\n')
    run(['chrome-devtools-axi','stop'],cwd=W)
else:
    raise AssertionError('Unexpected result; inspect transcript')
# Real bridge without opening local Chrome isolates record and unrelated-process guards.
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
print('Local Chrome regression FAILED; session ownership guards and parent preservation passed.')
