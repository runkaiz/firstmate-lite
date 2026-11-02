import os, pathlib, shutil, subprocess, time, json, signal
ROOT=pathlib.Path.cwd()
WORK=ROOT/'.test-watch-race'
EVIDENCE=pathlib.Path(__file__).parent
BASE='b3312f7464052666d996e97b97f37c84e69bcd88'
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_') or key in ('TMUX','TMUX_PANE'):
        env.pop(key,None)
env.update(PYTHONDONTWRITEBYTECODE='1', FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', TMUX_TMPDIR=str(WORK/'tmux'), TMPDIR=str(WORK))
(WORK/'tmux').mkdir(exist_ok=True)
basebin=WORK/'base-bin'
shutil.copytree(ROOT/'bin',basebin,dirs_exist_ok=True)
changed=subprocess.check_output(['git','diff','--name-only',BASE,'HEAD','--','bin'],text=True).splitlines()
for name in changed:
    (basebin/pathlib.Path(name).name).write_bytes(subprocess.check_output(['git','show',BASE+':'+name]))
results=[]
def wait_for(pred, seconds, why):
    end=time.monotonic()+seconds
    while time.monotonic()<end:
        if pred(): return
        time.sleep(.03)
    raise AssertionError(why)
def run(label, binary, action):
    home=WORK/label
    subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],env=env,check=True,stdout=subprocess.DEVNULL)
    (home/'config/usage-ledger').write_text('off\n')
    e=env|{'FM_HOME':str(home)}
    state=home/'state'
    holder=None; watcher=None
    log=EVIDENCE/(label+'.log'); trace=EVIDENCE/(label+'.trace')
    start=time.monotonic()
    try:
        with log.open('w') as out, trace.open('w') as err:
            watcher=subprocess.Popen(['bash','-x',str(binary/'fm-watch.sh')],env=e,stdout=out,stderr=err,start_new_session=True)
            wait_for(lambda: '+ sleep 1' in trace.read_text(),15,'watcher never completed first cycle')
            os.kill(watcher.pid, signal.SIGSTOP)
            holder=subprocess.Popen(['bash','-c',''' . "$1"; fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK" || exit 1; printf 'held\\n'; read -r release; fm_lock_release "$FM_WAKE_QUEUE_LOCK"''','_',str(binary/'fm-wake-lib.sh')],env=e,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
            assert holder.stdout.readline().strip()=='held'
            trace_offset=trace.stat().st_size
            os.kill(watcher.pid, signal.SIGCONT)
            needle='+ fm_lock_acquire_wait '+str(state/'.wake-queue.lock')
            wait_for(lambda: needle in trace.read_text()[trace_offset:] and trace.read_text()[trace_offset:].count('+ sleep 0.1')>=2,15,'watcher never waited for held queue lock')
            print(label+': real watcher pid='+str(watcher.pid)+' blocked on live queue holder pid='+str(holder.pid),flush=True)
            if action=='delete':
                shutil.rmtree(state)
                try:
                    rc=watcher.wait(timeout=4)
                    text=trace.read_text()
                    assert 'watcher: exiting - state directory no longer exists:' in text
                    assert not state.exists()
                    assert not any(line.startswith(('signal:','check:','stale:','heartbeat')) for line in log.read_text().splitlines())
                    assert rc==1
                    result='exited 1 with state-gone reason, no actionable wake, state remains absent'
                except subprocess.TimeoutExpired:
                    assert label.startswith('base'), 'fixed watcher hung after state removal'
                    result='still alive after 4 seconds: reproduced indefinite lock wait'
            else:
                assert watcher.poll() is None
                holder.stdin.write('release\n'); holder.stdin.flush(); assert holder.wait(timeout=5)==0
                wait_for(lambda: (state/'.last-watcher-beat').exists(),5,'no watcher beat')
                (state/'demo.status').write_text('needs-decision: choose export format\n')
                rc=watcher.wait(timeout=15)
                assert rc==0, (rc, trace.read_text()[-2000:])
                output=log.read_text()
                assert output.startswith('signal: ') and 'demo.status' in output, output
                queue=(state/'.wake-queue').read_text()
                assert 'demo.status' in queue,queue
                (EVIDENCE/(label+'.queue')).write_text(queue)
                result='waited without stealing live lock, then delivered signal and persisted wake after release'
            results.append({'case':label,'action':action,'result':result,'elapsed_seconds':round(time.monotonic()-start,2),'stdout':log.read_text()})
            print(label+': '+result,flush=True)
    finally:
        for proc in (watcher,holder):
            if proc and proc.poll() is None:
                os.killpg(proc.pid,signal.SIGTERM)
                try: proc.wait(timeout=3)
                except subprocess.TimeoutExpired:
                    os.killpg(proc.pid,signal.SIGKILL); proc.wait()
        shutil.rmtree(home,ignore_errors=True)
try:
    run('base-delete',basebin,'delete')
    for i in range(1,4): run('fixed-delete-'+str(i),ROOT/'bin','delete')
    run('fixed-release',ROOT/'bin','release')
finally:
    (EVIDENCE/'watch-race-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(basebin,ignore_errors=True)
