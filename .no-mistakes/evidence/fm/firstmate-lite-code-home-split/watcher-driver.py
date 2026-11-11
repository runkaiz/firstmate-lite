import os,sys,pathlib,subprocess,time,json,shlex
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M74F8VZ5BTPW2N5AC6ZD1V83'); E=pathlib.Path(sys.argv[1]); C=R/'.lv/share/firstmate'; homes=[R/'w1',R/'w2']; procs=[]; log=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k=='TMUX': env.pop(k,None)
env.update(HOME=str(R/'.lv/user'),XDG_DATA_HOME=str(R/'.lv/share'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',FM_BACKEND='tmux',FM_POLL='1',FM_HEARTBEAT='999999',FM_CHECK_INTERVAL='999999',FM_ARM_CONFIRM_TIMEOUT='5',FM_ARM_ATTACH_POLL='0.1',TMUX_TMPDIR=str(R/'l/tmux'))
def run(args,home=None):
    p=subprocess.run(['rtk',*map(str,args)],cwd=R,env={**env,**({'FM_HOME':str(home)} if home else {})},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=20)
    log.append('$ '+shlex.join(map(str,args))+'\n'+p.stdout+'[exit '+str(p.returncode)+']'); assert p.returncode==0,log[-1]; return p

def start(path,home,name):
    f=open(E/name,'w'); p=subprocess.Popen(['rtk',str(path)],cwd=R,env={**env,'FM_HOME':str(home)},stdout=f,stderr=subprocess.STDOUT); procs.append((p,f)); return p

def waitfor(check,seconds=12):
    until=time.monotonic()+seconds
    while time.monotonic()<until:
        if check(): return
        time.sleep(.1)
    raise RuntimeError('timed out waiting for live watcher')
try:
    for i,h in enumerate(homes):
        run([R/'bin/fm-lab-home.sh','create',h]); run([R/'bin/fm-install.sh',h]); start(h/'bin/fm-watch-arm.sh',h,'watch-home-'+str(i+1)+'.log')
        waitfor(lambda: (h/'state/.last-watcher-beat').exists() and 'watcher: started' in (E/('watch-home-'+str(i+1)+'.log')).read_text())
    pids=[(h/'state/.watch.lock/pid').read_text().strip() for h in homes]
    log.append('INITIAL OWNERS '+json.dumps(pids))
    peer=start(C/'bin/fm-watch-arm.sh',homes[0],'watch-install-peer.log')
    waitfor(lambda: 'watcher: attached pid='+pids[0] in (E/'watch-install-peer.log').read_text())
    assert [(h/'state/.watch.lock/pid').read_text().strip() for h in homes]==pids
    log.append('OBSERVED: the installed-code arm attached to the existing home-link watcher; both original watcher PIDs retained ownership.')
    run([C/'bin/fm-watch-arm.sh','--stop'],homes[0])
    assert (homes[1]/'state/.watch.lock/pid').read_text().strip()==pids[1]
    os.kill(int(pids[1]),0)
    log.append('OBSERVED: stop via installed code ended only the selected home watcher; the other home watcher remains alive with the same lock PID.')
    run([homes[1]/'bin/fm-watch-arm.sh','--stop'],homes[1])
finally:
    for h in homes:
        if (h/'state/.watch.lock/pid').exists():
            try: run([C/'bin/fm-watch-arm.sh','--stop'],h)
            except Exception as e: log.append(repr(e))
    for p,f in procs:
        try: p.wait(timeout=10)
        except subprocess.TimeoutExpired: p.terminate(); p.wait(timeout=10)
        f.close()
    (E/'watcher-transcript.log').write_text('\n\n'.join(log)+'\n')
