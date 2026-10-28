"""Real queue consumers and a private real tmux terminal; no model execution."""
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
HOME = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=ROOT / '.test-phase-tmp'))
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'TMUX'))}
env.update(FM_HOME=str(HOME), HOME=str(HOME), TMPDIR=str(ROOT / '.test-phase-tmp'), TMUX_TMPDIR=str(ROOT), FM_CREW_STATE_NO_FORGE='1', GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null')
log = (EVIDENCE / 'lifecycle-walkthrough.log').open('w')

def run(*args, codes=(0,)):
    argv = list(map(str, args))
    p = subprocess.run(argv, cwd=ROOT, env=env, text=True, capture_output=True, timeout=45)
    log.write('$ ' + shlex.join(argv).replace(str(HOME), '$LAB').replace(str(ROOT), '$WORKTREE') + '\n' + p.stdout + p.stderr + f'[exit {p.returncode}]\n\n')
    log.flush()
    assert p.returncode in codes, p.stdout + p.stderr
    return p.stdout + p.stderr

def q(*args):
    return run(ROOT / 'bin/fm-queue.sh', *args)

try:
    run(ROOT / 'bin/fm-lab-home.sh', 'create', HOME)
    (HOME / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    # The socket directory stays inside the worktree; no default server calls.
    run('tmux', '-L', 'fm-lab-queue-test', 'new-session', '-d', '-s', 'queue-lab', '-n', 'fm-stable', '-x', '100', '-y', '30', '-c', ROOT, 'sleep 600')
    env['TMUX'] = run('tmux', '-L', 'fm-lab-queue-test', 'display-message', '-p', '-t', 'queue-lab', '#{socket_path},#{pid},0').strip()
    q('add', 'stable', 'Accepted work')
    project = HOME / 'projects/demo'
    project.mkdir()
    run('git', 'init', project)
    run('git', '-C', project, 'remote', 'add', 'origin', 'https://example.test/disposable/demo.git')
    meta = HOME / 'state/stable.meta'
    meta.write_text(f'label=stable\nspawn_gen=1\nbackend=tmux\nwindow=queue-lab:fm-stable\nkind=scout\nmode=scout\nharness=codex\nworktree={project}\nproject={project}\n')
    transition = '''set -eu
. "$1/bin/fm-tasks-axi-lib.sh"
. "$1/bin/fm-backlog-transition-lib.sh"
fm_backlog_dispatch_transition "$2/state/stable.meta" "$2/data" stable "$2/state"
fm_backlog_dispatch_transition "$2/state/stable.meta" "$2/data" stable "$2/state"
cat "$2/state/stable.meta"
'''
    run('bash', '-c', transition, '_', ROOT, HOME)
    assert json.loads(q('show', 'stable', '--json'))['task']['state'] == 'in_flight'
    run(ROOT / 'bin/fm-captain-hold.sh', 'hold', 'scope-choice', '--title', 'Choose the scope', '--reason', 'Use the small or large scope?')
    env['FM_SEND_SETTLE'] = '0'
    run(ROOT / 'bin/fm-send.sh', 'stable', '--resolve-key', 'scope-choice', 'Use the small scope.', codes=(0, 1, 3))
    answered = json.loads(q('show', 'scope-choice', '--json'))['task']
    assert answered['state'] == 'done' and 'Use the small scope.' in answered['body']
    inbox = HOME / 'state/stable.inbox/001.msg'
    assert 'Use the small scope.' in inbox.read_text()
    log.write('Persisted steering inbox:\n' + inbox.read_text() + '\n')
    run(ROOT / 'bin/fm-crew-state.sh', 'stable')
    run('tmux', '-L', 'fm-lab-queue-test', 'kill-session', '-t', 'queue-lab')
    observed = run(ROOT / 'bin/fm-crew-state.sh', 'stable')
    assert 'state: done' not in observed and meta.exists()
    assert json.loads(q('show', 'stable', '--json'))['task']['state'] == 'in_flight'
    assert len([x for x in json.loads(q('list', '--json'))['tasks'] if x['id'] == 'stable']) == 1
    print('Repeated dispatch reconciliation preserved one binding; dead real terminal did not complete work.', flush=True)

    q('add', 'candidate', 'Queued until capacity is available')
    (HOME / 'config/project-capacity').write_text('demo 1\n')
    # Ordinary no-op guard is skipped only as the documented batch entry does;
    # admission is reached without a model, endpoint allocation, or fake CLI.
    env['FM_SPAWN_NO_GUARD'] = '1'
    env['FM_BACKEND'] = 'tmux'
    refused = run(ROOT / 'bin/fm-spawn.sh', 'candidate', project, '--scout', '--harness', 'codex', codes=(75,))
    assert 'backlog item stays queued' in refused
    assert not (HOME / 'state/candidate.meta').exists()
    assert not (HOME / 'data/candidate/launch-brief.md').exists()
    assert json.loads(q('show', 'candidate', '--json'))['task']['state'] == 'queued'
    # A real recorded handoff frees capacity through its owning calculation.
    with meta.open('a') as stream:
        stream.write('pr=https://example.test/disposable/demo/pull/1\n')
    check = '''set -eu
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-backend.sh"
. "$1/bin/fm-project-capacity-lib.sh"
fm_project_capacity_lookup "$FM_HOME/config" demo
lock=$(fm_treehouse_project_lock_path "$2")
fm_project_capacity_occupants "$lock" "$2" "$FM_HOME/state" candidate
printf 'capacity=%s occupants=%s\n' "$FM_PROJECT_CAPACITY" "$FM_PROJECT_CAPACITY_OCCUPANTS"
test "$FM_PROJECT_CAPACITY_OCCUPANTS" -lt "$FM_PROJECT_CAPACITY"
'''
    run('bash', '-c', check, '_', ROOT, project)
    assert 'candidate' in [x['id'] for x in json.loads(q('ready', '--json'))['tasks']]
    print('Real spawn refused at capacity without losing queued work; handoff made it eligible for reconsideration.', flush=True)
finally:
    subprocess.run(['tmux', '-L', 'fm-lab-queue-test', 'kill-server'], cwd=ROOT, env=env, capture_output=True)
    socket_dir = ROOT / f'tmux-{os.getuid()}'
    socket = socket_dir / 'fm-lab-queue-test'
    socket.unlink(missing_ok=True)
    if socket_dir.is_dir() and not any(socket_dir.iterdir()):
        socket_dir.rmdir()
    shutil.rmtree(HOME)
    log.write('Private terminal and disposable home removed.\n')
    log.close()
