import os, pathlib, subprocess, time, signal, re, json, shutil, traceback

ROOT = pathlib.Path(os.environ.get('WATCH_LIVE_CODE_ROOT', pathlib.Path.cwd()))
EVID = pathlib.Path(os.environ.get('WATCH_LIVE_EVIDENCE', '/home/runkai/.no-mistakes/evidence/01M7F6R6SC4DDMR2SEFJ7W1FZQ'))
EVID.mkdir(parents=True, exist_ok=True)
LAB = pathlib.Path.cwd() / '.watch-validation-tmp' / 'live-home'
env = dict(os.environ)
for k in list(env):
    if k.startswith('FM_') or k in ('TMUX', 'TMUX_PANE', 'HERDR_ENV', 'HERDR_SESSION', 'NO_MISTAKES_GATE'):
        env.pop(k)
env.update(FM_HOME=str(LAB), FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999', FM_ARM_CONFIRM_TIMEOUT='30')
processes = []
logs = []
results = []
socket_dir = None
transcript = (EVID / 'live-watcher-transcript.log').open('w')

def log(s):
    print(s, flush=True)
    transcript.write(s + '\n'); transcript.flush()

def run(args, check=True, **kwargs):
    p = subprocess.run(args, env=env, cwd=ROOT, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45, **kwargs)
    if check and p.returncode:
        raise RuntimeError(f'{args}: rc={p.returncode}\n{p.stdout}\n{p.stderr}')
    return p

def marker():
    p = LAB / 'state/.watcher-down'
    return p.read_text().strip() if p.exists() else '(absent)'

def live(pid):
    try:
        return pathlib.Path(f'/proc/{pid}/stat').read_text().split(') ')[1][0] != 'Z'
    except FileNotFoundError:
        return False

def watcher():
    return int((LAB / 'state/.watch.lock/pid').read_text())

def wait_for(pred, timeout=40):
    until = time.monotonic() + timeout
    while time.monotonic() < until:
        if pred(): return
        time.sleep(.1)
    raise AssertionError('deadline exceeded')

def start(name, args=(), predecessor=None):
    f = (EVID / f'{name}.log').open('w')
    logs.append(f)
    child_env = dict(env)
    if predecessor is not None:
        child_env['FM_WATCH_PREDECESSOR_ARM_PID'] = str(predecessor)
    p = subprocess.Popen([str(ROOT / 'bin/fm-watch-arm.sh'), *args], env=child_env, cwd=ROOT, stdout=f, stderr=subprocess.STDOUT)
    processes.append(p)
    path = EVID / f'{name}.log'
    wait_for(lambda: 'watcher: started pid=' in path.read_text() or p.poll() is not None)
    output = path.read_text()
    assert 'watcher: started pid=' in output or 'check: rearm-resurface' in output, output
    log(f'$ bin/fm-watch-arm.sh {" ".join(args)} [{name}, arm={p.pid}]\n{output.strip()}\nmarker={marker()}')
    return p, path

def append(key, payload):
    r = run(['bash', '-c', '. "$1/bin/fm-wake-lib.sh"; fm_wake_append signal "$2" "$3"', '_', str(ROOT), key, payload])
    log(f'captain event appended: {payload}; marker={marker()}')

def quiet(p, path, seconds=11):
    end = time.monotonic() + seconds
    while time.monotonic() < end:
        assert p.poll() is None, path.read_text()
        assert 'check: rearm-resurface' not in path.read_text(), path.read_text()
        time.sleep(.1)
    log(f'observed {seconds}s: arm={p.pid} remains live, watcher={watcher()}, no recovery wake, marker={marker()}')

def takeover(name, p):
    old = watcher()
    nxt, path = start(name, ['--take-over', str(p.pid)])
    wait_for(lambda: not live(old))
    assert 'check: rearm-resurface' not in path.read_text(), 'Takeover unexpectedly emitted a recovery wake:\n' + path.read_text()
    assert watcher() != old
    log(f'previous watcher={old} exited; only replacement singleton={watcher()} owns lab lock')
    return nxt, path

def delivered(p, path):
    p.wait(timeout=45)
    out = path.read_text()
    assert p.returncode == 0, out
    assert out.splitlines().count('check: rearm-resurface') == 1, out
    log(f'cycle closed rc=0 with exactly one recovery wake:\n{out.strip()}\nmarker={marker()}')

def snapshot(name):
    for filename in ('.watch-cycle-exits.log', '.watcher-down', '.wake-queue', '.watch-deliveries.log'):
        path = LAB / 'state' / filename
        if path.exists(): shutil.copyfile(path, EVID / f'{name}-{filename[1:]}')

try:
    run(['bin/fm-lab-home.sh', 'create', str(LAB)])
    (LAB / 'config/supervision-host-off').touch()
    (LAB / 'config/backend').write_text('tmux\n')
    socket_dir = run(['bin/fm-lab-home.sh', 'tmux-dir', str(LAB)]).stdout.strip()
    env['TMUX_TMPDIR'] = socket_dir
    launch = run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-x', '120', '-y', '40', '-s', 'primary', '-c', str(ROOT), '-e', f'FM_HOME={LAB}', 'claude'])
    time.sleep(6)
    cap = run(['tmux', '-L', 'fm-lab', 'capture-pane', '-p', '-t', 'primary'], check=False)
    (EVID / 'claude-primary-capture.txt').write_text(cap.stdout + cap.stderr)
    log('Real Claude launch, 120x40 private tmux pane:\n' + cap.stdout + cap.stderr)
    env['TMUX'] = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', 'primary', '#{socket_path},#{pid},0']).stdout.strip()
    # Public durable queue + real watcher; no fake runtime, backend, or engine.
    append('live-original', 'signal: existing work announced before turn end')
    p, path = start('initial-announcement')
    delivered(p, path)
    generation = marker().split(':')[-1]
    assert marker().startswith('announced:')
    owner, path = start('handling-successor', predecessor=p.pid)
    quiet(owner, path, 2)
    for i in range(3):
        owner, path = takeover(f'announced-takeover-{i+1}', owner)
        quiet(owner, path)
        assert marker() == f'announced:downtime:{generation}', marker()
    results.append({'name': 'Repeated turn-end takeovers preserve announced queued work without a recovery loop', 'result': 'pass'})
    snapshot('announced')

    drain = run(['bin/fm-wake-drain.sh'])
    log('$ bin/fm-wake-drain.sh\n' + drain.stdout + drain.stderr)
    pair = re.search(r'--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)', drain.stderr)
    assert pair, drain.stderr
    handling = marker()
    assert handling == f'announced:handling:{generation}', handling
    owner, path = takeover('handling-takeover', owner)
    quiet(owner, path)
    assert marker() == handling
    ack = run(['bin/fm-wake-drain.sh', '--ack-through', pair[1], '--recovery-generation', pair[2]])
    log('$ exact acknowledgement printed before take-over\n' + ack.stdout + ack.stderr)
    assert marker() == f'acked:handling:{generation}', marker()
    assert not (LAB / 'state/.wake-queue').read_text().strip()
    results.append({'name': 'A takeover during handling keeps the printed acknowledgement valid and consumes its rows', 'result': 'pass'})
    snapshot('handling-acked')

    for i in range(2):
        owner, path = takeover(f'acked-takeover-{i+1}', owner)
        quiet(owner, path)
        assert marker() == f'acked:handling:{generation}', marker()
    results.append({'name': 'Confirmed takeovers stay quiet with an acknowledged empty queue and supervision host disabled', 'result': 'pass'})

    append('live-later', 'signal: new work after confirmed takeover')
    delivered(owner, path)
    results.append({'name': 'New work arriving after a quiet takeover still resurfaces exactly once', 'result': 'pass'})
    snapshot('later-work')

    owner, path = start('before-kill-successor', predecessor=owner.pid)
    old = watcher()
    os.kill(old, signal.SIGKILL)
    wait_for(lambda: not live(old))
    assert watcher() == old
    log(f'Adversarial SIGKILL: watcher={old} dead while singleton lock still names it; marker={marker()}')
    recovery, recpath = start('killed-watcher-recovery', ['--take-over', str(owner.pid)])
    delivered(recovery, recpath)
    owner, path = start('after-kill-successor', predecessor=recovery.pid)
    owner, path = takeover('after-kill-takeover', owner)
    quiet(owner, path)
    results.append({'name': 'A killed watcher with queued work recovers once and the next confirmed takeover does not replay it', 'result': 'pass'})
    snapshot('killed-recovery')
except Exception:
    log(traceback.format_exc())
    results.append({'name': 'Current live watcher scenario', 'result': 'fail'})
    snapshot('failure')
finally:
    # Home-scoped stop before removing any state; only lab-owned processes.
    if LAB.exists():
        stopped = run(['bin/fm-watch-arm.sh', '--stop'], check=False)
        log('Lab cleanup: ' + stopped.stdout + stopped.stderr)
    for p in processes:
        if p.poll() is None:
            p.terminate()
    for p in processes:
        try: p.wait(timeout=8)
        except subprocess.TimeoutExpired: p.kill(); p.wait()
    if socket_dir:
        run(['tmux', '-L', 'fm-lab', 'kill-server'], check=False)
        run(['bin/fm-lab-home.sh', 'teardown', str(LAB)])
    shutil.rmtree(LAB, ignore_errors=True)
    log('Removed disposable lab home and stopped private tmux server.')
    (EVID / 'live-results.json').write_text(json.dumps(results, indent=2) + '\n')
    for f in logs: f.close()
    transcript.close()
if any(r['result'] == 'fail' for r in results): raise SystemExit(1)
