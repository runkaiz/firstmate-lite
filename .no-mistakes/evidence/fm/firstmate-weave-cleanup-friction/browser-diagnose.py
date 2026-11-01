from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT')
exec((E/'browser-checks.py').read_text().split("run(['ps'")[0])
log.write('=== Real local Chrome ownership failure (valid session record) ===\n')
out=td(*names);assert 'beside other process' in out;intact()
import re
pid=re.search(r'beside other process (\d+)',out).group(1)
run(['ps','-p',pid,'-o','pid,ppid,pgid,sid,args'])
run(['ps','-p',str(bridge),'-o','pid,ppid,pgid,sid,args'])
run(['readlink',f'/proc/{pid}/cwd'])
run(['chrome-devtools-axi','stop'],cwd=W)
# Counterfactual: the tool-owned stop removes the helper processes without intervention.
time.sleep(1)
run(['ps','-p',pid,'-o','pid,ppid,pgid,sid,args'],good=None)
run(['chrome-devtools-axi','stop'],cwd=L,extra={'CHROME_DEVTOOLS_AXI_SESSION':'fm-lab-unrelated'})
# Run a real browser outside the task copy and attach the task's real bridge.
chrome=env['CHROME_DEVTOOLS_AXI_EXECUTABLE_PATH']
chrome_log=open(E/'chrome-local.log','w')
child=subprocess.Popen([chrome,'--headless','--no-sandbox','--disable-dev-shm-usage','--remote-debugging-port=19441','--user-data-dir='+str(L/'cdp-profile'),'about:blank'],cwd=L,env=env,stdout=chrome_log,stderr=subprocess.STDOUT,start_new_session=True)
(E/'chrome-process.json').write_text(json.dumps({'pid':child.pid}))
import urllib.request
for _ in range(100):
    try:
        with urllib.request.urlopen('http://127.0.0.1:19441/json/version') as f: data=json.load(f)
        break
    except Exception:time.sleep(.1)
else:raise RuntimeError('Chrome did not start')
env['CHROME_DEVTOOLS_AXI_BROWSER_URL']='http://127.0.0.1:19441'
run(['chrome-devtools-axi','start'],cwd=W)
print('Confirmed crashpad process rejects local-browser cleanup; real attach-mode helper ready for remaining ownership checks.')
