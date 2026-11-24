import os, pathlib, subprocess as sp, time, json, signal, shutil, shlex
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M87RH602E3VG3Q41E3ZEDWGW')
EV=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M87RH602E3VG3Q41E3ZEDWGW')
LAB=ROOT/'.w'
SESSION='fm-lab-wake-gate-074c27d'
BASE_ENV=os.environ.copy()
for key in list(BASE_ENV):
    if key.startswith(('FM_', 'CLAUDE_CODE_', 'PI_', 'TASKS_AXI_')) or key in ('CLAUDECODE','CLAUDE_PID','TMUX','TMUX_PANE','NO_MISTAKES_GATE','GROK_AGENT','GROK_HOOK_EVENT'):
        BASE_ENV.pop(key,None)
BASE_ENV.update(FM_HERDR_LAB_STATE_DIR=str(ROOT/'.wake-live/herdr-state'), DISABLE_AUTOUPDATER='1', CLAUDE_CODE_DISABLE_AUTO_MEMORY='1', CLAUDE_CODE_ENABLE_PROMPT_SUGGESTION='false')
logfile=(EV/'live-print-transcript.log').open('w')
def log(s):
    line=time.strftime('%H:%M:%S')+' '+str(s)
    print(line,flush=True); logfile.write(line+'\n'); logfile.flush()
def run(args,env=None,check=True):
    r=sp.run(args,cwd=ROOT,env=env or BASE_ENV,text=True,stdout=sp.PIPE,stderr=sp.STDOUT)
    if check and r.returncode: raise RuntimeError(f'{args}: {r.returncode}\n{r.stdout}')
    return r.stdout

def herdr(*args,check=True): return run(['bash','bin/fm-herdr-lab.sh','run',SESSION,*args],check=check)
TMENV=None

def tmux(*args,check=True): return run(['tmux','-L','fm-lab',*args],env=TMENV,check=check)
def screen():
    try: return (LAB/'primary.jsonl').read_text()
    except FileNotFoundError: return tmux('capture-pane','-p','-S','-100','-t','primary',check=False)
def capture(label):
    s=screen(); (EV/(label+'.txt')).write_text(s); log(s[-6500:]); return s

def wait(pred,sec,label):
    until=time.time()+sec
    while time.time()<until:
        if pred(): return
        time.sleep(.3)
    capture('timeout-'+label)
    for f in (LAB/'state').glob('.supervision-host*'):
        if f.is_file(): shutil.copyfile(f,EV/('timeout-'+f.name.lstrip('.')))
    raise TimeoutError(label)
def read(name):
    try: return (LAB/'state'/name).read_text()
    except FileNotFoundError: return ''
def watcher_live():
    try: os.kill(int(read('.watch.lock/pid').strip()),0); return True
    except (ValueError,ProcessLookupError): return False

def send(text):
    tmux('send-keys','-t','primary','-l',text); time.sleep(.8); tmux('send-keys','-t','primary','Enter')

def transcript():
    # The actual path is captured from Claude's dialog-mirror record, never searched on host.
    for line in read('.host-mirror.jsonl').splitlines():
        pass
    project=str(ROOT).replace('/','-').replace('.','-')
    # project transcript path obtained through hook payload in lab settings instead.
    payload=LAB/'last-stop.json'
    if payload.exists():
        return pathlib.Path(json.loads(payload.read_text()).get('transcript_path',''))
    return None

def save_transcript():
    if (LAB/'primary.jsonl').exists(): shutil.copyfile(LAB/'primary.jsonl',EV/'primary-stream.jsonl')
    p=transcript()
    if p and p.is_file(): shutil.copyfile(p,EV/'claude-session.jsonl')

def append(text,kind='working'):
    with (LAB/'state/demo.status').open('a') as f: f.write(f'{kind} [at={int(time.time())}]: {text}\n')

def stop_engine():
    value=read('.supervision-host.engine-pid')
    if value:
        pid=int(value.split()[0]); os.kill(pid,signal.SIGSTOP); return pid
    return None

try:
    if LAB.exists(): raise RuntimeError('lab path already exists')
    run(['bash','bin/fm-lab-home.sh','create',str(LAB)])
    (LAB/'tmux').mkdir()
    TMENV=BASE_ENV|{'TMUX_TMPDIR':str(LAB/'tmux'),'FM_HOME':str(LAB)}
    # Scope the split-home lab as a primary on a linked worktree, through the supported marker.
    marker=ROOT/'.fm-secondmate-home'
    if marker.exists(): raise RuntimeError('primary marker already exists')
    marker.write_text('wake-test-lab\n')
    (LAB/'config/supervision-host').write_text('claude haiku\n')
    (LAB/'config/backend').write_text('tmux\n')
    # Use tracked Stop and mirror hooks; acquire the real lock at session start, without bootstrap.
    settings=json.loads((ROOT/'.claude/settings.json').read_text())
    settings['hooks']['SessionStart']=[{'hooks':[{'type':'command','command':str(ROOT/'bin/fm-lock.sh')}]}]
    settings['hooks']['Stop'].append({'hooks':[{'type':'command','command':'cat > '+shlex.quote(str(LAB/'last-stop.json'))}]})
    (LAB/'settings.json').write_text(json.dumps(settings))
    TMENV.update(FM_POLL='1',FM_SIGNAL_GRACE='0',FM_CHECK_INTERVAL='999999',FM_HEARTBEAT='999999',FM_SUPERVISION_HOST_PARK_SECONDS='600',FM_SUPERVISION_HOST_TURN_TIMEOUT='180',FM_BACKEND_HERDR_EVENTS_FORCE='0')
    # Actual Herdr commands invoked by the adapter are routed through the guarded lab helper.
    (LAB/'bin').mkdir()
    realpath=BASE_ENV['PATH']
    (LAB/'bin/herdr').write_text('#!/usr/bin/env python3\n'+f'import os,sys\na=sys.argv[1:]; out=[]\nwhile a:\n x=a.pop(0)\n if x=="--session":\n  assert a.pop(0)=={SESSION!r}\n else: out.append(x)\nos.environ["PATH"]={realpath!r}\nos.execvp("bash",["bash",{str(ROOT/"bin/fm-herdr-lab.sh")!r},"run",{SESSION!r},*out])\n')
    (LAB/'bin/herdr').chmod(0o755)
    TMENV['PATH']=str(LAB/'bin')+':'+realpath
    log('Provision named isolated Herdr session (helper also records prepare tripwire)')
    log(run(['bash','bin/fm-herdr-lab.sh','provision',SESSION]))
    log(herdr('status','--json'))
    log('Start real Claude print primary in private tmux, 160 x 48 grid, from gate worktree; print mode skips workspace trust')
    tmux('-f','/dev/null','new-session','-d','-s','primary','-x','160','-y','48','-c',str(ROOT),'-e','FM_HOME='+str(LAB),
         'claude -p '+shlex.quote('This is an isolated Firstmate lab. Reply READY only. On every later Stop hook feedback, run bin/fm-wake-drain.sh with Bash, then run its exact WAKE_ACK_REQUIRED acknowledgement command, then reply ACKED. Never run another command or tool. After ACKED, stop; the Stop hook owns watcher continuity.')+' --model haiku --effort low --dangerously-skip-permissions --setting-sources "" --settings '+shlex.quote(str(LAB/'settings.json'))+' --strict-mcp-config --mcp-config \'{"mcpServers":{}}\' --output-format stream-json --verbose --system-prompt '+shlex.quote('You are an isolated Firstmate live-test primary. Operate only the disposable FM_HOME in the environment. Follow only the tester prompt. Never delegate, read operator data, change source, or change global configuration.')+' > '+shlex.quote(str(LAB/'primary.jsonl'))+' 2>&1')
    tmux('new-window','-t','primary','-n','worker','-c',str(ROOT),'while :; do date +%s; sleep 1; done')
    (LAB/'state/demo.meta').write_text('project=demo\nwindow=primary:worker\nbackend=tmux\nharness=claude\nkind=ship\n')
    (LAB/'state/demo.status').write_text('')
    (LAB/'data/demo').mkdir()
    (LAB/'data/demo/brief.md').write_text('Disposable live supervision test. Working updates are routine observations; no recovery, project, or publication actions are authorized.\n')
    wait(lambda: bool(read('.lock').strip()),100,'primary-lock')
    log('Real primary owns session lock '+read('.lock').strip())
    wait(watcher_live,100,'first-watcher')
    log('Primary idle; watcher live '+read('.watch.lock/pid').strip())
    append('routine progress update in isolated lab')
    wait(lambda: bool(read('.supervision-host.engine-pid')),100,'real-engine-start')
    engine=stop_engine(); log('Paused actual Claude engine PID '+str(engine)+' to deterministically hold cleanup race')
    (LAB/'state/retiring.meta').write_text(f'project=demo\nwindow={SESSION}:w1:p999999\nbackend=herdr\nharness=claude\nkind=ship\n')
    wait(lambda:'herdr: agent missing' in read('.wake-queue'),60,'missing-endpoint-wake')
    log('Durable wake before cleanup:\n'+read('.wake-queue'))
    run(['bash','-c','. bin/fm-wake-lib.sh; fm_wake_queue_prune_task "$FM_HOME/state" retiring "'+SESSION+':w1:p999999"'],env=TMENV)
    (LAB/'state/retiring.meta').unlink()
    log('Durable queue after supported task wake retirement:\n'+read('.wake-queue'))
    os.kill(engine,signal.SIGCONT)
    wait(lambda:'\tsettled\tstale:' in read('.supervision-host.log'),180,'settled-stale')
    wait(watcher_live,30,'watcher-after-cleanup')
    log('Host retained park after cleanup:\n'+read('.supervision-host.log'))
    save_transcript()
    append('LIVE_AFTER_CLEANUP: choose A or B','needs-decision')
    wait(lambda:'ACKED' in screen(),180,'later-decision-delivery')
    capture('later-decision-delivered')
    log('Decision delivered; queue after primary acknowledgement:\n'+read('.wake-queue'))
    wait(watcher_live,60,'next-park')
    # Adversarial: keep the stale row and metadata. It must still reach main.
    (LAB/'state/unresolved.meta').write_text(f'project=demo\nwindow={SESSION}:w1:p999998\nbackend=herdr\nharness=claude\nkind=ship\n')
    wait(lambda:'pass-through\tattended\tmain-only\tstale: unresolved' in read('.supervision-host.log'),90,'unresolved-stale-pass-through')
    wait(lambda:'unresolved' in screen(),120,'unresolved-stale-primary')
    capture('unresolved-stale-delivered')
    log('Unresolved stale reached main:\n'+read('.supervision-host.log'))
    save_transcript()
    log('LIVE SCENARIOS PASSED')
except Exception as e:
    log('LIVE BLOCKER OR FAILURE: '+repr(e))
    if TMENV: capture('final-screen'); save_transcript()
finally:
    if LAB.exists():
        for f in (LAB/'state').glob('.*'):
            if f.is_file() and f.name in ('.supervision-host.log','.watch-cycle-exits.log','.wake-queue','.claude-autoarm-epoch','.watcher-down','.host-mirror.jsonl'):
                shutil.copyfile(f,EV/f.name.lstrip('.'))
        if TMENV: tmux('kill-server',check=False)
        # Stop only PIDs recorded by this disposable home.
        host=read('.supervision-host')
        for line in host.splitlines():
            fields=line.split('\t')
            if fields[0] in ('host','arm') and len(fields)>1:
                try: os.kill(int(fields[1]),signal.SIGTERM)
                except (ProcessLookupError,ValueError): pass
        try: os.kill(int(read('.watch.lock/pid').strip()),signal.SIGTERM)
        except (ProcessLookupError,ValueError): pass
        time.sleep(2)
    log('Herdr teardown: '+run(['bash','bin/fm-herdr-lab.sh','teardown',SESSION],check=False))
    if (ROOT/'.fm-secondmate-home').exists(): (ROOT/'.fm-secondmate-home').unlink()
    shutil.rmtree(LAB,ignore_errors=True)
    log('Disposable primary home and scope marker removed')
