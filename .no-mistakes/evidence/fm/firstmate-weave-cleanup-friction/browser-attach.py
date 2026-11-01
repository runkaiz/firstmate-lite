from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT')
exec((E/'browser-checks.py').read_text().split("rec=L/")[0])
# Run a real browser outside the task copy and attach the task's real bridge.
env['TMPDIR']='/tmp'
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
