"""Drive production watcher/drain/runner in disposable worktree-local homes.

The queued notice and process output are synthetic input data. No pipeline,
forge, model, backend command, or production record is substituted or driven.
"""
import os
import pathlib
import re
import subprocess
import tempfile
import time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path(__file__).parent
LOG = open(EVIDENCE / 'live-delivery.log', 'w', buffering=1)
PR = 'https://github.com/example/disposable/pull/123'

def note(text):
    LOG.write(text + '\n')
    print(text, flush=True)

def run(argv, env, check=True):
    proc = subprocess.run(argv, env=env, cwd=ROOT, text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    LOG.write('$ ' + ' '.join(map(str, argv)) + '\n' + proc.stdout + proc.stderr)
    if check and proc.returncode:
        raise RuntimeError(f'{argv[0]} exited {proc.returncode}: {proc.stderr}')
    return proc

def watch(env, output, script='bin/fm-watch.sh'):
    stream = open(EVIDENCE / output, 'w')
    proc = subprocess.Popen([str(ROOT / script)], env=env, cwd=ROOT,
                            stdout=stream, stderr=subprocess.STDOUT)
    return proc, stream

def stop(pair):
    proc, stream = pair
    if proc.poll() is None:
        proc.terminate()
        proc.wait(timeout=10)
    stream.close()

def output(name):
    return (EVIDENCE / name).read_text()

def ack(drain, env):
    match = re.search(r'WAKE_ACK_REQUIRED:.*(bin/fm-wake-drain.sh --ack-through \d+ --recovery-generation [\w.-]+)', drain.stderr)
    assert match, drain.stderr
    run(match[1].split(), env)

def queue(env, key):
    payload = f'check: no-mistakes CI wait has zero registered checks after 10 minutes - task=disposable pr={PR}; tell the captain with this PR URL, zero checks are not green, do not merge; see validation-supervision'
    run(['bash', '-c', '. bin/fm-wake-lib.sh; fm_wake_append check "$1" "$2"', '_', key, payload], env)

def quiet_watch(env, name, duration=4):
    pair = watch(env, name)
    try:
        time.sleep(duration)
        assert pair[0].poll() is None, output(name)
        assert 'check:' not in output(name), output(name)
        beat = pathlib.Path(env['FM_HOME']) / 'state/.last-watcher-beat'
        assert time.time() - beat.stat().st_mtime < 3
        note(f'{name}: watcher remained live with a fresh heartbeat and no repeated check wake for {duration}s')
    finally:
        stop(pair)

base_env = {key: val for key, val in os.environ.items()
            if not key.startswith('FM_') and key not in ('TMUX', 'HERDR_SESSION', 'HERDR_ENV')}
base_env['TMPDIR'] = str(ROOT / '.test-phase-tmp')
old_watcher = ROOT / 'bin/.test-fm-watch-before.sh'
pairs = []
try:
    old_watcher.write_bytes(subprocess.check_output(['git', 'show', '04dccf2baaac0aa0fe4d5bda9e8c0a8d46c94353:bin/fm-watch.sh']))
    old_watcher.chmod(0o700)
    for version in ('before', 'after'):
        with tempfile.TemporaryDirectory(prefix='fm-lab.', dir=ROOT / '.test-phase-tmp') as labdir:
            env = dict(base_env, FM_HOME=labdir, FM_BACKEND='tmux',
                       FM_PROCEVENT_CLAIM_ROOT=labdir + '/claims',
                       FM_WATCH_HANDLING_SUCCESSOR='1', FM_POLL='0.2',
                       FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999',
                       TMUX=labdir + '/tmux/unstarted-private-socket,0,0')
            run(['bin/fm-lab-home.sh', 'create', labdir], env)
            note(f'{version}: marked lab created; backend is real tmux directed only at an unstarted private socket; no fleet panes exist')
            queue(env, 'ci-no-checks:DISPOSABLE1')
            filename = version + '-notice-watch.log'
            pair = watch(env, filename, 'bin/.test-fm-watch-before.sh' if version == 'before' else 'bin/fm-watch.sh')
            pairs.append(pair)
            if version == 'before':
                time.sleep(4)
                assert pair[0].poll() is None, output(filename)
                assert 'zero registered checks' not in output(filename)
                beat = pathlib.Path(labdir) / 'state/.last-watcher-beat'
                assert time.time() - beat.stat().st_mtime < 3
                note('BASELINE REPRODUCED: a queued zero-check notice does not wake the healthy predecessor watcher')
                stop(pair)
                continue
            pair[0].wait(timeout=10)
            stop(pair)
            assert pair[0].returncode == 0
            assert 'check: no-mistakes CI wait has zero registered checks: ci-no-checks:DISPOSABLE1' in output(filename)
            note('CURRENT: healthy watcher proactively emitted the zero-check headline for the queued key')
            drain = run(['bin/fm-wake-drain.sh'], env)
            assert PR in drain.stdout and 'zero checks are not green, do not merge' in drain.stdout
            assert 'PROCEVENT_HANDLED_REQUIRED' not in drain.stderr
            (EVIDENCE / 'notice-drain.txt').write_text(drain.stdout + drain.stderr)
            quiet_watch(env, 'notice-rearm-watch.log')
            ack(drain, env)
            queue(env, 'ci-no-checks:DISPOSABLE2')
            pair = watch(env, 'new-round-watch.log')
            pairs.append(pair)
            pair[0].wait(timeout=10)
            stop(pair)
            assert 'ci-no-checks:DISPOSABLE2' in output('new-round-watch.log')
            note('NEW ROUND: a distinct no-check key wakes again; deduplication does not suppress future waits')
            ack(run(['bin/fm-wake-drain.sh'], env), env)

            # A real external process yields deterministic data for the production
            # CI adapter/runner. This never invokes or controls no-mistakes.
            result = f'ci_wait: action\ntask: disposable\nrun_id: DISPOSABLE3\npr: {PR}\nevidence:\noutcome: checks-passed\n'
            input_path = pathlib.Path(labdir) / 'process-output.txt'
            input_path.write_text(result)
            run(['bin/fm-procevent.sh', 'register', 'ci', 'ci-disposable3', '--',
                 '/usr/bin/cat', str(input_path)], env)
            run(['bin/fm-procevent.sh', 'ensure-listening', 'ci-disposable3'], env)
            capture = pathlib.Path(labdir) / 'state/procevent-inbox/ci-disposable3.1.result'
            for _ in range(100):
                if capture.exists() and 'procevent:ci-disposable3:1' in (pathlib.Path(labdir) / 'state/.wake-queue').read_text():
                    break
                time.sleep(.1)
            assert capture.exists()
            note('RUNNER: real registered process output was captured durably and published')
            classification = run(['bin/fm-procevent.sh', 'classify', str(capture)], env)
            assert classification.stdout.strip() == 'action'
            (EVIDENCE / 'captured-result.txt').write_text(capture.read_text())
            drain = run(['bin/fm-wake-drain.sh'], env)
            handled = 'bin/fm-procevent.sh handled ci-disposable3 1'
            assert handled in drain.stderr
            (EVIDENCE / 'result-drain.txt').write_text(drain.stdout + drain.stderr)
            ack(drain, env)
            run(['bin/fm-procevent.sh', 'reconcile'], env)
            assert 'procevent:ci-disposable3:1' in (pathlib.Path(labdir) / 'state/.wake-queue').read_text()
            note('ADVERSARIAL: acknowledging wake rows alone republishes the still-unhandled result')
            drain = run(['bin/fm-wake-drain.sh'], env)
            assert handled in drain.stderr
            first = run(handled.split(), env)
            second = run(handled.split(), env)
            assert first.stdout.strip() == 'handled: ci-disposable3 1'
            assert second.stdout.strip() == 'already-handled: ci-disposable3 1'
            ack(drain, env)
            for _ in range(3):
                run(['bin/fm-procevent.sh', 'reconcile'], env)
            assert not (pathlib.Path(labdir) / 'state/.wake-queue').read_text().strip()
            quiet_watch(env, 'handled-result-watch.log')
            note('HANDLED: repeated acknowledgement is idempotent; three reconciles and a healthy successor watcher do not reannounce')
            run(['bin/fm-brief.sh', 'disposable', 'example', '--mode', 'no-mistakes'], env)
            brief = pathlib.Path(labdir) / 'data/disposable/brief.md'
            (EVIDENCE / 'generated-handoff.md').write_text(brief.read_text())
            note('GENERATED INTERFACE: saved the real worker brief; this does not establish that a live worker writes the requested PR-bearing paused status')
        note(f'{version}: disposable lab removed')
finally:
    for pair in pairs:
        stop(pair)
    old_watcher.unlink(missing_ok=True)
    LOG.close()
