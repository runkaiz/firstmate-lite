import os, pathlib, subprocess, tempfile, time, shutil, re

ROOT = pathlib.Path(os.environ.get('VALIDATION_SOURCE', '/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M64TZWBQA10NCA1ZZX5VRMAT'))
EVIDENCE = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M64TZWBQA10NCA1ZZX5VRMAT')
lab = pathlib.Path(tempfile.mkdtemp(prefix='.watch-lab-', dir=ROOT))
home = lab/'home'
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_')) and k not in ['TMUX','NO_MISTAKES_GATE']}
env.update(FM_HOME=str(home), FM_POLL='1', FM_SIGNAL_GRACE='1', FM_CHECK_INTERVAL='999999',
           FM_HEARTBEAT='999999', FM_WATCH_HANDLING_SUCCESSOR='1')
log = (EVIDENCE/(os.environ.get('VALIDATION_LABEL', 'live')+'-watcher.log')).open('w', buffering=1)
proc = None
socket = None

def run(*args, quiet=False, ok=True):
    r = subprocess.run(args, cwd=ROOT, env=env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=30)
    if not quiet: log.write('$ '+' '.join(map(str,args))+'\n'+r.stdout+f'[exit {r.returncode}]\n')
    if ok: assert r.returncode == 0, r.stdout
    return r.stdout

def tmux(*args, **kw): return run('tmux','-L','fm-lab',*args,**kw)

def seen():
    run('bash','-c','. bin/fm-wake-lib.sh; sig=$(fm_wake_signal_sig "$2"); fm_wake_status_reported_commit "$1" "$2" "$sig"; fm_wake_status_seen_commit "$1" "$2" "$3" "$(_fm_open_decisions_file_ident "$2")"','_',str(home/'state'),str(home/'state'/'delivery.status'),str((home/'state'/'delivery.status').stat().st_size),quiet=True)

def queue():
    f = home/'state'/'.wake-queue'
    return f.read_text() if f.exists() else ''

def start():
    global proc
    out = (EVIDENCE/'live-watcher-process.log').open('a')
    proc = subprocess.Popen(['bash','bin/fm-watch.sh'], cwd=ROOT, env=env, stdout=out, stderr=subprocess.STDOUT)
    out.close()

def stop():
    global proc
    if proc and proc.poll() is None:
        proc.terminate(); proc.wait(timeout=20)
    proc = None

def surface(label):
    tmux('send-keys','-t','test:fm-delivery',"printf '%s\\n' '"+label+"'",'Enter')
    start()
    try: proc.wait(timeout=45)
    except subprocess.TimeoutExpired:
        stop(); raise AssertionError('No wake: '+label)
    log.write('WAKE '+label+'\n'+queue())
    assert '\tstale\ttest:fm-delivery\t' in queue(), queue()
    stop()

def ack():
    out = run('bash','bin/fm-wake-drain.sh')
    m = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',out)
    assert m, out
    run('bash','bin/fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2])
    assert not queue().strip(), queue()

def quiet(label):
    tmux('send-keys','-t','test:fm-delivery',"printf '%s\\n' '"+label+"'",'Enter')
    start()
    beat = home/'state'/'.last-watcher-beat'
    stamps=set()
    end=time.time()+40
    while time.time()<end and len(stamps)<5:
        assert proc.poll() is None, 'Unexpected wake: '+queue()
        if beat.exists(): stamps.add(int(beat.stat().st_mtime))
        time.sleep(.25)
    assert len(stamps)>=5, 'Watcher did not complete enough cycles'
    assert not queue().strip(), queue()
    log.write(f'QUIET {label}: {len(stamps)} distinct live beacon timestamps; no queued wake\n')
    stop()

try:
    run('bash','bin/fm-lab-home.sh','create',str(home))
    socket=run('bash','bin/fm-lab-home.sh','tmux-dir',str(home)).strip()
    env['TMUX_TMPDIR']=socket
    env['TMUX']=socket+'/tmux-'+str(os.getuid())+'/fm-lab,0,0'
    (home/'config'/'backlog-backend').write_text('manual\n')
    (home/'config'/'usage-ledger').write_text('off\n')
    tmux('-f','/dev/null','new-session','-d','-s','test','-n','fm-delivery','-x','120','-y','40','-c',str(lab),'/bin/bash --noprofile --norc')
    state=home/'state'
    if os.environ.get('VALIDATION_AWAY') == '1':
        (state/'.afk').touch()
        log.write('Watcher fixture is in away mode.\n')
    (state/'delivery.meta').write_text('window=test:fm-delivery\nkind=ship\nharness=sleep\nbackend=tmux\n')
    (state/'delivery.status').write_text('done: delivered result\n')
    seen()
    surface('first delivered result')
    ack()
    quiet('idle redraw')
    markers=list(state.glob('.terminal-resurfaced-*'))
    assert len(markers)==1, str(markers)
    stamp=time.time()-50000
    os.utime(markers[0],(stamp,stamp))
    log.write('Aged actual delivery suppression marker by 50000 seconds (13.9 hours).\n')
    quiet('idle redraw after twelve hours')
    with (state/'delivery.status').open('a') as f: f.write('needs-decision [key=new]: choose release\n')
    seen()
    surface('new decision after done')
    ack()
    with (state/'delivery.status').open('a') as f: f.write('resolved [key=new]: selected release\ndone: second delivery\n')
    seen()
    surface('resolved call and second delivery')
    ack()
    quiet('second delivery idle')
    replacement=state/'replacement'
    replacement.write_text((state/'delivery.status').read_text())
    replacement.replace(state/'delivery.status')
    seen()
    surface('new status generation')
    ack()
    tmux('capture-pane','-p','-t','test:fm-delivery')
    log.write('ALL LIVE WATCHER SCENARIOS PASSED\n')
finally:
    stop()
    if socket:
        tmux('kill-server',ok=False)
        run('bash','bin/fm-lab-home.sh','teardown',str(home))
    shutil.rmtree(lab)
    log.write('Disposable watcher lab and private tmux server removed.\n')
    log.close()
