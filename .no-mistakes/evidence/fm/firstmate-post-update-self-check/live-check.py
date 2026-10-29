import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M62N2AYVWBQFB4KXEE7WECX5')
WORK = ROOT / '.test-phase-tmp/live'
EVIDENCE = Path('/home/runkai/.no-mistakes/evidence/01M62N2AYVWBQFB4KXEE7WECX5')
WORK.mkdir()
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_', 'GIT_CONFIG_')):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid',
           GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid',
           TMPDIR=str(ROOT / '.test-phase-tmp'))

def run(args, home=None, cwd=None, check=True, timeout=40):
    local = env.copy()
    if home:
        local['FM_HOME'] = str(home)
    result = subprocess.run([str(x) for x in args], cwd=cwd or ROOT, env=local,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
                            timeout=timeout)
    if check and result.returncode:
        raise RuntimeError(f'{args}: exit {result.returncode}\n{result.stdout}')
    return result

def git(path, *args):
    return run(['git', '-C', path, *args]).stdout.strip()

def home(name):
    path = WORK / name
    run([ROOT / 'bin/fm-lab-home.sh', 'create', path])
    return path

def fleet():
    h = home('fleet')
    log = []
    origin = h / 'origin.git'
    seed = h / 'seed'
    git(h, 'init', '-q', '-b', 'main', str(seed))
    (seed / 'file').write_text('v1\n')
    git(seed, 'add', 'file')
    git(seed, 'commit', '-qm', 'initial')
    git(h, 'clone', '-q', '--bare', str(seed), str(origin))
    git(seed, 'remote', 'add', 'origin', str(origin))
    for name in ('historical', 'normal', 'unlanded'):
        git(h, 'clone', '-q', str(origin), str(h / 'projects' / name))
    historical = h / 'projects/historical'
    unlanded = h / 'projects/unlanded'
    for path in (historical, unlanded):
        git(path, 'switch', '-qc', 'unfinished')
        (path / 'local').write_text('keep my unlanded work\n')
        git(path, 'add', 'local')
        git(path, 'commit', '-qm', 'unlanded')
        (path / 'dirty').write_text('keep my dirty work\n')
    (seed / 'file').write_text('v2\n')
    git(seed, 'commit', '-qam', 'advance')
    git(seed, 'push', '-q', 'origin', 'main')
    registry = h / 'data/projects.md'
    registry.write_text('- historical [direct-PR +yolo branch= retained-history] - archived\n'
                        '- normal [direct-PR] - active\n'
                        '- unlanded [direct-PR] - active unfinished work\n')
    before = git(historical, 'show-ref')
    dirty = (historical / 'dirty').read_bytes()
    for flag in ('--raw', '--branch-prefix', '--forge', '--retained-history'):
        out = run([ROOT / 'bin/fm-project-mode.sh', flag, 'historical'], h).stdout
        log.append(f'$ fm-project-mode.sh {flag} historical\n{out}')
    assert run([ROOT / 'bin/fm-project-mode.sh', 'historical'], h).stdout.strip() == 'direct-PR on'
    assert run([ROOT / 'bin/fm-project-mode.sh', '--branch-prefix', 'historical'], h).stdout == '\n'
    unlanded_head = git(unlanded, 'rev-parse', 'HEAD')
    out = run([ROOT / 'bin/fm-fleet-sync.sh'], h).stdout
    log.append('$ fm-fleet-sync.sh\n' + out)
    assert 'historical: skipped: retained historical clone (delivery policy unchanged)' in out
    assert 'unlanded: STUCK:' in out
    assert git(historical, 'show-ref') == before
    assert (historical / 'dirty').read_bytes() == dirty
    assert git(unlanded, 'rev-parse', 'HEAD') == unlanded_head
    assert (unlanded / 'dirty').read_text() == 'keep my dirty work\n'
    assert git(h / 'projects/normal', 'rev-parse', 'HEAD') == git(seed, 'rev-parse', 'HEAD')
    log.append('Observed: all retained refs and dirty bytes unchanged; normal clone fast-forwarded; unlanded branch and dirty bytes preserved.\n')
    registry.write_text(registry.read_text().replace(' retained-history', ''))
    out = run([ROOT / 'bin/fm-fleet-sync.sh', 'historical'], h).stdout
    log.append('$ fm-fleet-sync.sh historical # annotation removed\n' + out)
    assert 'STUCK:' in out
    assert git(historical, 'rev-parse', 'HEAD') == unlanded_head
    assert (historical / 'dirty').read_bytes() == dirty
    (EVIDENCE / 'fleet-live.log').write_text('\n'.join(log).replace(str(WORK), '<disposable-lab>'))
    print('fleet live checks passed', flush=True)

def pr_case(name, rows, rejected):
    h = home(name)
    state = h / 'state'
    repo = h / 'projects/demo'
    git(h, 'init', '-q', '-b', 'main', str(repo))
    (repo / 'file').write_text('local lab\n')
    git(repo, 'add', 'file')
    git(repo, 'commit', '-qm', 'initial')
    meta = state / 'a-worker.meta'
    meta.write_text(f'kind=ship\nmode=no-mistakes\nproject={repo}\nworktree={repo}\nspawn_gen=s123.456.789\n')
    result = run([ROOT / 'bin/fm-pr-check.sh', 'a-worker', 'https://github.com/cli/cli/pull/1'], h)
    log = ['$ fm-pr-check.sh a-worker https://github.com/cli/cli/pull/1\n' + result.stdout]
    # Execute the production receipt writer; the input state models an already-stopped worker.
    writer = '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-afk-capacity-lib.sh"; fm_afk_capacity_receipt_write "$2" stopped'
    run(['bash', '-c', writer, '_', ROOT, meta], h)
    with meta.open('a') as f:
        f.write('control_relaunch_tx=42.20261029T010203Z.123\n' + rows)
    log.append('Persisted lifecycle metadata:\n' + meta.read_text())
    local = env.copy()
    local.update(FM_HOME=str(h), FM_CHECK_INTERVAL='0', FM_POLL='0.05', FM_HEARTBEAT='999999', FM_SIGNAL_GRACE='0')
    result = subprocess.run([str(ROOT / 'bin/fm-watch.sh')], cwd=ROOT, env=local,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=45)
    log.append(f'$ fm-watch.sh\nexit={result.returncode}\n{result.stdout}')
    if rejected:
        assert 'rejected unauthenticated state checks:' in result.stdout, result.stdout
        assert (state / 'a-worker.check.sh').exists()
        assert not (state / 'a-worker.merge-notified').exists()
    else:
        assert result.returncode == 0 and 'a-worker.check.sh: merged' in result.stdout, result.stdout
        assert not (state / 'a-worker.check.sh').exists()
    for p in sorted(state.glob('*')):
        if p.is_file() and ('merge' in p.name or p.name == '.wake-queue'):
            log.append(f'Persisted {p.name}:\n{p.read_text()}')
    assert not (ROOT / 'sentinel').exists()
    (EVIDENCE / f'{name}.log').write_text('\n'.join(log).replace(str(WORK), '<disposable-lab>'))
    print(name, 'passed', flush=True)

try:
    fleet()
    pr_case('pr-lifecycle-live', '', False)
    pr_case('pr-duplicate-live', 'afk_worker_stopped=legacy\n', True)
    pr_case('pr-injection-live', 'pr_head=$(touch sentinel)\n', True)
finally:
    shutil.rmtree(WORK)
