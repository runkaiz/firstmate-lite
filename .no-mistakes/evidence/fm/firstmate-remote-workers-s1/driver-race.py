from common import *
focus(); sync(); run(['bin/fm-peek.sh','pilot','32'])
wt=fields('pilot.meta')['worktree']; sha=run(['git','-C',wt,'rev-parse','HEAD']).stdout.strip(); assert (pathlib.Path(wt)/'hello.txt').read_text()=='remote pilot\n'; assert sha==fields('pilot.remote')['last_imported']; note('CUSTODY VERIFIED: remote Claude commit imported onto landing branch before paused status')
ssh("printf 'needs-decision [at=3] [key=live-race]: choose continuation\\n' >> "+remote+'/channel/status'); sync()
ssh("printf 'needs-decision [at=3] [key=live-race]: live pending journal payload\\n' >> "+remote+'/channel/status')
r=run(['bin/fm-remote-task.sh','sync','fm-pilot'],{'FM_REMOTE_TEST_CRASH':'after-journal'},check=False); assert r.returncode==99; assert (state/'pilot.remote-journal').exists()
ssh("printf 'working [at=4]: live after concurrent recovery\\n' >> "+remote+'/channel/status')
wr=pilot/'transport'; wr.mkdir(exist_ok=True)
(wr/'ssh').write_text('#!/usr/bin/env python3\nimport os,sys,subprocess,time,pathlib\nif sys.argv[-1]!="/bin/bash -s": os.execv("/usr/bin/ssh",["/usr/bin/ssh"]+sys.argv[1:])\nr=subprocess.run(["/usr/bin/ssh"]+sys.argv[1:],input=sys.stdin.buffer.read(),stdout=subprocess.PIPE)\nif sys.argv[-1]=="/bin/bash -s":\n pathlib.Path(os.environ["LIVE_READY"]).touch()\n for i in range(600):\n  if pathlib.Path(os.environ["LIVE_RELEASE"]).exists(): break\n  time.sleep(.05)\nsys.stdout.buffer.write(r.stdout)\nsys.exit(r.returncode)\n'); (wr/'ssh').chmod(0o700)
e=dict(env,PATH=str(wr)+':'+env['PATH'],LIVE_READY=str(pilot/'ready'),LIVE_RELEASE=str(pilot/'release'))
with (ev/'live-race-held-sync.log').open('w') as out:
 p=subprocess.Popen(['bin/fm-remote-task.sh','sync','fm-pilot'],env=e,cwd=root,stdout=out,stderr=subprocess.STDOUT)
 try:
  for i in range(600):
   if (pilot/'ready').exists(): break
   if p.poll() is not None: raise RuntimeError('held sync exited early')
   time.sleep(.05)
  assert (pilot/'ready').exists(), 'real SSH response never reached pause'
  run(['bin/fm-send.sh','pilot','--resolve-key','live-race','The journal-race probe is resolved. Keep waiting for the completion instruction.'])
  off=fields('pilot.remote')['status_offset']; assert not (state/'pilot.remote-journal').exists(); (pilot/'release').touch(); assert p.wait(timeout=45)==0
 finally:
  (pilot/'release').touch()
  if p.poll() is None: p.terminate(); p.wait()
s=(state/'pilot.status').read_text(); assert s.count('live pending journal payload')==1; assert 'live after concurrent recovery' not in s; assert fields('pilot.remote')['status_offset']==off; assert not (state/'pilot.remote-alert').exists(); note('STALE RESPONSE DISCARDED: original fetched cursor rejected after local answer recovered journal')
sync(); sync(); s=(state/'pilot.status').read_text(); assert s.count('live pending journal payload')==1 and s.count('live after concurrent recovery')==1; assert s.index('live pending journal payload')<s.index('[key=live-race]: answered') if '[key=live-race]: answered' in s else True
note('EXACTLY ONCE VERIFIED after recovery:\n'+s)
run(['bash','-c','. bin/fm-classify-lib.sh; status_open_decisions "$FM_HOME/state/pilot.status"'])
