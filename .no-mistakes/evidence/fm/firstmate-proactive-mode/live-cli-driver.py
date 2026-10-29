import os, subprocess, pathlib, json, concurrent.futures
root=pathlib.Path.cwd()
home=root/'.validation/home'
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M64BCXTFANZT4W6PV57S5R9Z')
env=os.environ.copy()
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','TASKS_AXI_FILE','TASKS_AXI_BACKEND']:
 env.pop(k,None)
env['FM_HOME']=str(home)
log=[]
def run(script,*args,expected=0):
 c=['bash','bin/'+script,*args]
 r=subprocess.run(c,env=env,text=True,capture_output=True,timeout=25)
 log.append('$ '+' '.join(c)+'\n'+r.stdout+r.stderr+f'[exit {r.returncode}]\n')
 assert r.returncode==expected,(c,r.returncode,r.stderr)
 return r.stdout
try:
 pref=home/'config/proactive'
 assert run('fm-proactive.sh','status').strip()=='PROACTIVE MODE: off'
 assert not pref.exists()
 baseline=run('fm-supervision-instructions.sh','--harness','codex')
 assert run('fm-proactive.sh').strip()=='PROACTIVE MODE: on'
 assert pref.read_bytes()==b'on\n'
 assert run('fm-proactive.sh','status').strip()=='PROACTIVE MODE: on'
 for harness in ['claude','codex','opencode','pi','pi-signed','grok','cursor','omp','unknown']:
  out=run('fm-supervision-instructions.sh','--harness',harness)
  assert 'PROACTIVE MODE: on' in out
  (ev/('supervision-'+harness+'.txt')).write_text(out)
 out=run('fm-wake-drain.sh')
 assert 'PROACTIVE MODE: on' in out and '/proactive/policy.md' in out
 assert 'automatic merge authority' not in out
 run('fm-brief.sh','proactive-live-on','fixture','--mode','no-mistakes')
 brief=(home/'data/proactive-live-on/brief.md').read_text()
 (ev/'brief-proactive-on.md').write_text(brief)
 assert 'invoke /no-mistakes immediately on this same worker' in brief
 # Execute the actual preference recheck delivered in the generated brief.
 line=next(x for x in brief.splitlines() if x.startswith('When implementation is committed'))
 check=line.split('`')[1]
 r=subprocess.run(['bash','-c',check],env=env,text=True,capture_output=True)
 log.append('$ '+check+'\n'+r.stdout)
 assert r.returncode==0 and r.stdout.strip()=='PROACTIVE MODE: on'
 run('fm-proactive.sh','off')
 r=subprocess.run(['bash','-c',check],env=env,text=True,capture_output=True)
 log.append('$ '+check+'\n'+r.stdout)
 assert r.returncode==0 and r.stdout.strip()=='PROACTIVE MODE: off'
 assert run('fm-supervision-instructions.sh','--harness','codex')==baseline
 run('fm-brief.sh','proactive-live-off','fixture','--mode','no-mistakes')
 brief=(home/'data/proactive-live-off/brief.md').read_text()
 (ev/'brief-proactive-off.md').write_text(brief)
 assert 'Firstmate will then instruct you to run /no-mistakes' in brief
 assert 'invoke /no-mistakes immediately' not in brief
 for data in [b'ON\n',b'on\n\n',b'on\x00\n',b'yes',b'']:
  pref.write_bytes(data)
  log.append('Persisted invalid bytes: '+repr(data)+'\n')
  assert run('fm-proactive.sh','instructions').startswith('PROACTIVE MODE: off')
  run('fm-proactive.sh','toggle',expected=1)
  assert pref.read_bytes()==data
  run('fm-proactive.sh','off')
 pref.unlink();pref.mkdir()
 run('fm-proactive.sh','on',expected=1)
 pref.rmdir()
 run('fm-proactive.sh','off')
 with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
  results=list(pool.map(lambda _:run('fm-proactive.sh','toggle'),range(8)))
 assert run('fm-proactive.sh','status').strip()=='PROACTIVE MODE: off'
 assert sum(x.strip()=='PROACTIVE MODE: on' for x in results)==4
 print('Live preference, malformed-state refusal, concurrent toggles, supervision delivery, wake refresh, brief generation, and action-time recheck passed.')
finally:
 (ev/'live-cli-transcript.txt').write_text('\n'.join(log))
