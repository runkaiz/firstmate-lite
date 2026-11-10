import os,sys,subprocess,json,time,shutil
from pathlib import Path
ROOT=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73T6KEWT536RR3MJ2AYEEYA');E=Path('/home/runkai/.no-mistakes/evidence/01M73T6KEWT536RR3MJ2AYEEYA');R=ROOT/'.test-runtime/boundary';R.mkdir()
env=dict(os.environ)
for key in list(env):
 if key.startswith('HERDR_') or key.endswith('_OVERRIDE') or key in ['FM_HOME','FM_GATE_REFUSE_BYPASS','FM_TASK_ID']:env.pop(key,None)
(R/'user-home').mkdir(exist_ok=True)
env.update(HOME=str(R/'user-home'),XDG_DATA_HOME=str(R/'user-home/data'),XDG_CACHE_HOME=str(R/'user-home/cache'),HERDR_CONFIG_PATH=str(E/'h/herdr/lab-config.toml'),XDG_CONFIG_HOME=str(E/'h'),FM_HERDR_LAB_STATE_DIR=str(R/'owner'),TMPDIR=str(ROOT/'.test-runtime'))
helper=ROOT/'bin/fm-herdr-lab.sh';session='fm-lab-b';log=open(E/'boundary-product.log','w',buffering=1);sock=None;watch=None;tm=False

def run(*a,ee=None,check=True):
 p=subprocess.run([str(x) for x in a],env=ee or env,cwd=ROOT,capture_output=True,text=True,timeout=30)
 log.write('$ '+' '.join(str(x) for x in a)+'\n'+p.stdout+p.stderr+'\n');print(str(a[0]).split('/')[-1],flush=True)
 if check and p.returncode:raise RuntimeError(p.stdout+p.stderr)
 return p

def lab(*a,check=True):return run(helper,'run',session,*a,check=check)
try:
 run(helper,'provision',session)
 pane=json.loads(lab('workspace','create','--cwd',R,'--label','unreadable','--no-focus').stdout)['result']['root_pane']['pane_id']
 lab('pane','run',pane,'sleep 300');lab('pane','report-agent',pane,'--source','fm-live-boundary','--agent','claude','--state','idle')
 h=R/'home';run(ROOT/'bin/fm-lab-home.sh','create',h)
 (h/'state/native.meta').write_text(f'backend=herdr\nwindow={session}:{pane}\nkind=scout\nharness=claude\nworktree={R}\n')
 een={**env,'FM_HOME':str(h)}
 # Positive native lifecycle busy evidence must survive an idle inter-tool state.
 run(ROOT/'bin/fm-busy-event.sh','arm',h/'state','native','--state','busy','--source','claude-hook','--event','UserPromptSubmit',ee=een)
 out=run(ROOT/'bin/fm-crew-state.sh','native',ee=een).stdout
 assert 'state: working' in out and 'claude-hook' in out,out
 run(ROOT/'bin/fm-busy-event.sh','apply',h/'state','native','idle','--current-gen','--source','claude-hook','--event','Stop',ee=een)
 assert 'state: idle' in run(ROOT/'bin/fm-crew-state.sh','native',ee=een).stdout
 socket_info=json.loads(lab('session','list','--json').stdout)
 sock=Path(next(x['socket_path'] for x in socket_info['sessions'] if x['name']==session));mode=sock.stat().st_mode&0o777
 sock.chmod(0)
 lab('pane','get',pane,check=False)
 lab('status','--json',check=False)
 out=run(ROOT/'bin/fm-crew-state.sh','native',ee=een).stdout
 run('bash','-c','. "$1/bin/fm-backend.sh"; fm_backend_source herdr; fm_backend_herdr_agent_state "$2" activity','_',ROOT,session+':'+pane,ee=een)
 assert 'state: unknown' in out and 'gone' not in out,out
 log.write('Unreadable socket crew result: '+out+'\n')
 f=open(E/'unreadable-watcher.log','w')
 watch=subprocess.Popen([str(ROOT/'bin/fm-watch.sh')],env={**een,'FM_POLL':'1','FM_SIGNAL_GRACE':'1','FM_CHECK_INTERVAL':'999999','FM_HEARTBEAT':'999999','FM_BACKEND_HERDR_EVENTS_FORCE':'0'},cwd=ROOT,stdout=f,stderr=subprocess.STDOUT)
 beat=h/'state/.last-watcher-beat';limit=time.monotonic()+20;first=None;completed=False
 while time.monotonic()<limit and watch.poll() is None:
  if beat.exists():
   stamp=beat.stat().st_mtime_ns
   if first is None:first=stamp
   elif stamp!=first:completed=True;break
  time.sleep(.1)
 assert completed,'unreadable watcher did not finish a complete poll cycle'
 assert watch.poll() is None,'unreadable socket woke watcher'
 assert not (h/'state/.wake-queue').exists(),'unreadable socket queued recovery'
 watch.terminate();watch.wait(15);f.close();watch=None
 log.write('PASS unreadable live socket produced unknown state and no recovery wake\n')
 sock.chmod(mode);sock=None
 # Use an actual private tmux server and the same public status interface.
 t=E/'t';t.mkdir(exist_ok=True);envt={**env,'TMUX_TMPDIR':str(t)}
 run('tmux','-L','fm-lab','new-session','-d','-s','checks','-n','fm-fallback','-x','120','-y','40','-c',R,'sleep 300',ee=envt);tm=True
 socket=run('tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},0',ee=envt).stdout.strip()
 ht=R/'tmux-home';run(ROOT/'bin/fm-lab-home.sh','create',ht)
 (ht/'state/fallback.meta').write_text(f'backend=tmux\nwindow=checks:fm-fallback\nkind=scout\nharness=claude\nworktree={R}\n')
 (ht/'state/fallback.status').write_text('needs-decision: approve the release\n')
 envt.update(TMUX=socket,FM_HOME=str(ht),FM_POLL='1',FM_SIGNAL_GRACE='1',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999')
 run(ROOT/'bin/fm-busy-event.sh','arm',ht/'state','fallback','--state','idle','--source','claude-hook','--event','Stop',ee=envt)
 out=run(ROOT/'bin/fm-crew-state.sh','fallback',ee=envt).stdout;assert 'state: parked' in out,out
 p=run('timeout','20',ROOT/'bin/fm-watch.sh',ee=envt);assert 'signal:' in p.stdout,p.stdout
 log.write('TMUX persisted wake:\n'+(ht/'state/.wake-queue').read_text())
 log.write('PASS tmux fallback captain decision still wakes through the status contract\n')
finally:
 if watch is not None and watch.poll() is None:watch.terminate();watch.wait(15)
 if sock is not None:sock.chmod(mode)
 if tm:
  run('tmux','-L','fm-lab','kill-server',ee=envt)
  shutil.rmtree(E/'t')
 run(helper,'teardown',session)
 shutil.rmtree(R)
 log.close()
