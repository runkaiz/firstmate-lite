from common import *
import re
sshconfig=pathlib.Path.home()/'.ssh/config'; original=sshconfig.read_text(); assert original.startswith('Host fm-pilot-pegasus\n')
def ack():
 r=run(['bin/fm-wake-drain.sh']); m=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through ([0-9]+)(?: --recovery-generation ([A-Za-z0-9._-]+))?',r.stdout)
 if m:
  a=['bin/fm-wake-drain.sh','--ack-through',m[1]]
  if m[2]: a+=['--recovery-generation',m[2]]
  run(a)
def watch(label,seconds):
 e=dict(env,FM_POLL='1',FM_SIGNAL_GRACE='1',FM_REMOTE_SYNC_SECS='2',FM_REMOTE_DOWN_GRACE_SECS='8',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999',FM_SECONDMATE_LIVENESS_SECS='99999999')
 path=ev/('live-outage-'+label+'.log')
 with path.open('w') as out:
  p=subprocess.Popen(['bin/fm-watch.sh'],cwd=root,env=e,stdout=out,stderr=subprocess.STDOUT)
  try: p.wait(timeout=seconds)
  except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=10)
 text=path.read_text(); note('SUPERVISION '+label+':\n'+text); return text
try:
 sshconfig.write_text(original.replace('HostName pegasus','HostName 192.0.2.1'))
 note('CONNECTION CUT: only fm-pilot-pegasus alias points to 192.0.2.1')
 sync(); assert fields('.remote-link-966df3cddb5e527a693a675d66d27109')['state']=='unreachable'
 before_meta=(state/'pilot.meta').read_bytes(); before_remote=(state/'pilot.remote').read_bytes()
 if not any('This is the outage steering probe.' in p.read_text() for p in (state/'pilot.inbox').glob('*.msg')):
  run(['bin/fm-send.sh','pilot','This is the outage steering probe. Append working status with token outage-ack-once, acknowledge this inbox file once, and remain waiting.'])
 queued=list((state/'pilot.inbox').glob('*.msg')); assert queued; counts={p.name:p.read_bytes() for p in (state/'pilot.inbox').glob('*') if p.is_file()}
 cs=run(['bin/fm-crew-state.sh','pilot']).stdout; assert 'state: working' in cs and 'worker state unknown (not proof of death)' in cs
 for action in ['exit','relaunch']:
  a=['bin/fm-control.sh','pilot',action]
  if action=='relaunch': a+=['--note','Outage probe: preserve the existing task and remain waiting.']
  r=run(a,check=False); assert r.returncode!=0 and ('refusing' in r.stdout or 'reachable' in r.stdout)
 r=run(['bin/fm-remote-task.sh','retire','pilot','prepare'],check=False); assert r.returncode!=0
 assert (state/'pilot.meta').read_bytes()==before_meta and (state/'pilot.remote').read_bytes()==before_remote
 run(['ssh','-o','BatchMode=yes','pegasus',"grep -q written-during-cut-one /Users/runkai/firstmate-remote-pilot/tasks/pilot/channel/status || printf 'working [at=7]: written-during-cut-one\\nworking [at=8]: written-during-cut-two\\n' >> "+remote+'/channel/status'])
 text=''
 for j in range(6):
  one=watch('down-'+str(j),25); text+=one; assert 'stale:' not in one; ack()
  if 'has been unreachable' in text: break
 assert text.count('has been unreachable')==1
 text2=watch('still-down',12); assert 'has been unreachable' not in text2 and 'stale:' not in text2
 for name,data in counts.items(): assert (state/'pilot.inbox'/name).read_bytes()==data, 'offline instruction retry budget changed'
 assert all(p.exists() for p in queued); note('OUTAGE VERIFIED: unknown link, worker declaration preserved, lifecycle/cleanup refused, records intact, one grace notice, no stale or retry budget changes')
finally:
 sshconfig.write_text(original); note('CONNECTION RESTORED: only pilot alias restored')
run(['ssh','-o','BatchMode=yes','fm-pilot-pegasus','true']); sync()
text=''
for j in range(6):
 one=watch('return-'+str(j),30); text+=one; ack()
 if 'is reachable again' in text: break
assert text.count('is reachable again')==1
sync(); s=(state/'pilot.status').read_text(); assert s.count('written-during-cut-one')==1 and s.count('written-during-cut-two')==1 and s.index('written-during-cut-one')<s.index('written-during-cut-two')
for i in range(8):
 sync()
 if 'outage-ack-once' in (state/'pilot.status').read_text() and not list((state/'pilot.inbox').glob('*.msg')): break
 time.sleep(2)
s=(state/'pilot.status').read_text(); note('RETURN STATUS:\n'+s); assert s.count('outage-ack-once')==1; assert not list((state/'pilot.inbox').glob('*.msg'))
ssh('ls -1 '+remote+'/channel/inbox/handled; ls -1 '+remote+'/channel/inbox/.placed')
sync(); assert (state/'pilot.status').read_text().count('outage-ack-once')==1; note('RETURN VERIFIED: status in order once, queued instructions acknowledged once and not resurrected'); focus()
