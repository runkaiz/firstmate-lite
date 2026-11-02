import os, pathlib, subprocess, signal, shutil, time
ROOT=pathlib.Path.cwd(); WORK=ROOT/'.test-watch-race'; E=pathlib.Path(__file__).parent
home=WORK/'boundary'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(home),PYTHONDONTWRITEBYTECODE='1',TMPDIR=str(WORK),TMUX_TMPDIR=str(WORK/'tmux'))
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(home)],env=env,check=True,stdout=subprocess.DEVNULL)
holder=None; writer=None
try:
    # Source once, then remove state before invoking the public queue append interface.
    command=' . "$1"; rm -rf -- "$STATE"; fm_wake_append check boundary "check: must not be written"; rc=$?; printf "append status=%s state_exists=" "$rc"; if [ -d "$STATE" ]; then echo yes; else echo no; fi; [ "$rc" -eq 1 ] && [ ! -e "$STATE" ]'
    p=subprocess.run(['bash','-c',command,'_',str(ROOT/'bin/fm-wake-lib.sh')],env=env,capture_output=True,text=True,timeout=4)
    print(p.stdout.strip()); assert p.returncode==0,p.stderr
    # A normal preference write still succeeds.
    p=subprocess.run(['bash','bin/fm-proactive.sh','on'],env=env,capture_output=True,text=True,timeout=5)
    assert p.returncode==0 and (home/'config/proactive').read_text()=='on\n',p.stderr
    print('normal preference write: '+p.stdout.strip())
    holder=subprocess.Popen(['bash','-c',''' . "$1"; fm_lock_acquire_wait "$FM_HOME/config/.proactive.lock" || exit 1; echo held; read -r release; fm_lock_release "$FM_HOME/config/.proactive.lock"''','_',str(ROOT/'bin/fm-wake-lib.sh')],env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,start_new_session=True)
    assert holder.stdout.readline().strip()=='held'
    trace=E/'proactive-deleted-config.trace'
    with trace.open('w') as err:
        writer=subprocess.Popen(['bash','-x','bin/fm-proactive.sh','off'],env=env,stdout=subprocess.PIPE,stderr=err,text=True,start_new_session=True)
        end=time.monotonic()+5
        while trace.read_text().count('+ sleep 0.1')<2:
            assert time.monotonic()<end,'writer did not contend on lock'
            time.sleep(.03)
        shutil.rmtree(home/'config')
        rc=writer.wait(timeout=4)
        output=writer.stdout.read()
        assert rc==1 and not output and not (home/'config').exists(),(rc,output)
        print('preference writer blocked on real lock: deleting config returns status=1, no success output, config remains absent')
finally:
    for p in (writer,holder):
        if p and p.poll() is None:
            os.killpg(p.pid,signal.SIGTERM)
            try: p.wait(timeout=2)
            except subprocess.TimeoutExpired: os.killpg(p.pid,signal.SIGKILL); p.wait()
    shutil.rmtree(home,ignore_errors=True)
