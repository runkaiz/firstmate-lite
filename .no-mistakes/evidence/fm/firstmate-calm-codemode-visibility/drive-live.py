import subprocess,time,pathlib,json
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M61Q2TFMG98XD2R55EMBXAH4'); home=pathlib.Path('.calm-validation/live')
def keys(*args):subprocess.run(['tmux','-L','fm-calm-live-validation','send-keys','-t','primary',*args],check=True)
def cmd(s):keys('-l',s);keys('M-s')
def logs():return [json.loads(x) for x in (E/'live-timers.jsonl').read_text().splitlines()]
def wait(fn,timeout=12):
 end=time.time()+timeout
 while time.time()<end:
  if fn():return
  time.sleep(.06)
 raise AssertionError('Timed out')
def snap(name):
 text=subprocess.check_output(['tmux','-L','fm-calm-live-validation','capture-pane','-p','-t','primary'],text=True);(E/(name+'.txt')).write_text(text);return text
report=[]
for outcome in ['success','error','abort','hidden-success','negative']:
 want='on' if outcome in ['hidden-success','negative'] else 'off'
 if (home/'config/calm').read_text().strip()!=want:cmd('/calm');wait(lambda:(home/'config/calm').read_text().strip()==want)
 time.sleep(.3);before=len(logs());cmd(outcome)
 wait(lambda:any(x['event']=='execute' for x in logs()[before:]));time.sleep(.3)
 partial=snap('live-'+outcome+'-partial-'+want)
 if outcome=='negative':assert 'UNRELATED_CUSTOM_CALL' in partial
 elif want=='off':assert 'text(await tools.fixture_delay' in partial
 else:assert 'text(await tools.fixture_delay' not in partial
 if want=='off':cmd('/calm');wait(lambda:(home/'config/calm').read_text().strip()=='on');time.sleep(.3)
 hidden=snap('live-'+outcome+'-running-on')
 if outcome!='negative':assert 'text(await tools.fixture_delay' not in hidden,hidden
 if outcome=='abort':keys('Escape')
 wait(lambda:any(x['event']=='agent-end' for x in logs()[before:]),15);time.sleep(1.4)
 cmd('/probe-state');time.sleep(.2)
 events=logs()[before:];assert events[-1]['event']=='probe' and events[-1]['active']==0,events
 if outcome!='negative':
  assert any(x['event']=='timer-start' for x in events),events
  assert any(x['event']=='timer-clear' for x in events),events
  clear=max(i for i,x in enumerate(events) if x['event']=='timer-clear');assert not any(x['event']=='timer-tick' for x in events[clear+1:]),events
 complete=snap('live-'+outcome+'-complete-on')
 if outcome=='negative':assert 'UNRELATED_CUSTOM_RESULT' in complete
 else:assert 'text(await tools.fixture_delay' not in complete
 cmd('/calm');wait(lambda:(home/'config/calm').read_text().strip()=='off');time.sleep(.3)
 restored=snap('live-'+outcome+'-restored-off')
 if outcome!='negative':assert 'text(await tools.fixture_delay' in restored
 report.append({'outcome':outcome,'result':'pass','events':events});print(outcome,'PASS',flush=True)
(E/'live-scenario-results.json').write_text(json.dumps(report,indent=2))
