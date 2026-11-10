import json
import os
from pathlib import Path
import subprocess
import time
import shlex
import shutil

root = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73FXDW27CZ6BKZQR9ZYJN1V')
evidence = Path('/home/runkai/.no-mistakes/evidence/01M73FXDW27CZ6BKZQR9ZYJN1V')
home = root / '.test-usage-removal/lifecycle'
env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
for key in ('FM_GATE_REFUSE_BYPASS', 'TMUX', 'CLAUDECODE', 'PI_CODING_AGENT', 'FM_PI_HARNESS', 'FM_TASK_ID'):
    env.pop(key, None)
env.update(FM_HOME=str(home), DISABLE_AUTOUPDATER='1', GIT_CONFIG_NOSYSTEM='1',
           GIT_CONFIG_GLOBAL='/dev/null', GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid',
           GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
task = 'ledger-removal-' + str(os.getpid())
log = []

def run(args, timeout=120, check=True):
    result = subprocess.run(args, env=env, text=True, capture_output=True, timeout=timeout, cwd=root)
    log.append('$ ' + ' '.join(args) + '\n' + result.stdout + result.stderr + '\nexit=' + str(result.returncode))
    (evidence / 'live-lifecycle.txt').write_text('\n'.join(log) + '\n')
    if check:
        assert result.returncode == 0, log[-1]
    return result

def wait_stopped(endpoint):
    # Escape begins an asynchronous runtime exit. Wait for its real shell
    # before asking Firstmate to relaunch or retire the endpoint.
    for _ in range(50):
        command = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', endpoint,
                       '#{pane_current_command}']).stdout.strip()
        if command in ('bash', 'zsh', 'fish', 'sh'):
            return
        time.sleep(0.1)
    raise RuntimeError('Codex did not return to its shell after declining trust')

run(['bin/fm-lab-home.sh', 'create', str(home)])
socket_dir = run(['bin/fm-lab-home.sh', 'tmux-dir', str(home)]).stdout.strip()
env['TMUX_TMPDIR'] = socket_dir
try:
    # Execute the installed CLI, adding its documented private-server flag.
    # This wrapper supplies no responses and does not simulate the runtime.
    cli = root / '.test-usage-removal/cli'
    cli.mkdir(exist_ok=True)
    actual_codex = shutil.which('codex')
    assert actual_codex
    (cli / 'codex').write_text('#!/usr/bin/env bash\nexec ' + shlex.quote(actual_codex) + ' --no-daemon "$@"\n')
    (cli / 'codex').chmod(0o755)
    env['PATH'] = str(cli) + ':' + env['PATH']
    (home / 'config/backend').write_text('tmux\n')
    (home / 'config/crew-harness').write_text('codex\n')
    (home / 'config/backlog-backend').write_text('manual\n')
    (home / 'config/worktree-allocator').write_text('git\n')
    (home / 'config/git-worktree-root').write_text(str(root / '.test-usage-removal/copies') + '\n')
    (home / 'config/fleet-ledger').touch()
    (home / 'config/supervision-host-off').touch()
    project = home / 'projects/sample'
    run(['git', 'init', '-q', '-b', 'main', str(project)])
    (project / 'README.md').write_text('Disposable lifecycle validation project.\n')
    run(['git', '-C', str(project), 'add', 'README.md'])
    run(['git', '-C', str(project), 'commit', '-qm', 'Initial lab project'])
    run(['bin/fm-brief.sh', task, 'sample', '--mode', 'local-only', '--project', str(project)])
    brief = home / 'data' / task / 'brief.md'
    text = brief.read_text().replace('{TASK}',
        'This is a disposable product validation. Make no source or configuration changes. '
        'Append exactly one done status line using the status command in these instructions, '
        'then wait silently. No investigation, delegation, validation, commits, or publication is needed.')
    text = text.replace('{FIRSTMATE_SPEC}',
        'The no-op task is complete immediately. Write the done status and wait. '
        'Remain confined to this disposable project and the task-owned status file.')
    brief.write_text(text)
    run(['tmux', '-L', 'fm-lab', '-f', '/dev/null', 'new-session', '-d', '-s', 'primary',
         '-x', '160', '-y', '45', '-c', str(root), 'bash --noprofile --norc'])
    env['TMUX'] = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '#{socket_path},#{pid},0']).stdout.strip()
    # Invoke the public Firstmate launch, with its real native allocator and real Codex TUI.
    run(['bin/fm-spawn.sh', task, str(project), '--mode', 'local-only', '--yolo', 'off', '--harness', 'codex'])
    meta = home / 'state' / (task + '.meta')
    fields = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line)
    (evidence / 'lifecycle-before-meta.txt').write_text(meta.read_text())
    endpoint = fields['window']
    reached_trust = False
    for _ in range(30):
        pane = run(['tmux', '-L', 'fm-lab', 'capture-pane', '-p', '-S', '-160', '-t', endpoint]).stdout
        (evidence / 'codex-worker-pane.txt').write_text(pane)
        status = home / 'state' / (task + '.status')
        if status.exists() and 'done' in status.read_text():
            break
        if 'Trust this folder?' in pane:
            reached_trust = True
            break
        if 'Sign in' in pane or 'sign in' in pane or 'Hooks need review' in pane:
            raise RuntimeError('Real Codex reached an authentication or hook review gate; see pane evidence')
        time.sleep(1)
    else:
        raise RuntimeError('Worker did not reach a rendered Codex UI within 30 polls; see pane evidence')
    assert not (home / 'data/usage-ledger').exists()
    # A model turn is unnecessary for these metadata lifecycle side effects.
    # Escape declines the trust dialog and quits Codex without persisting consent.
    if reached_trust:
        run(['bin/fm-control.sh', task, 'interrupt'], check=False)
        wait_stopped(endpoint)
    original_generation = fields['spawn_gen']
    original_copy = fields['worktree']
    run(['bin/fm-control.sh', task, 'relaunch', '--harness', 'codex', '--note', 'Repeat the same no-op status update; make no files or configuration changes.'])
    updated = dict(line.split('=', 1) for line in meta.read_text().splitlines() if '=' in line)
    (evidence / 'lifecycle-after-meta.txt').write_text(meta.read_text())
    assert updated['spawn_gen'] != original_generation and updated['worktree'] == original_copy
    assert not (home / 'data/usage-ledger').exists()
    time.sleep(4)
    pane = run(['tmux', '-L', 'fm-lab', 'capture-pane', '-p', '-S', '-160', '-t', endpoint]).stdout
    (evidence / 'codex-relaunched-pane.txt').write_text(pane)
    if 'Trust this folder?' in pane:
        run(['bin/fm-control.sh', task, 'interrupt'], check=False)
        wait_stopped(endpoint)
    run(['bin/fm-control.sh', task, 'exit'])
    run(['bin/fm-teardown.sh', task])
    assert not meta.exists()
    assert not Path(original_copy).exists()
    assert not (home / 'data/usage-ledger').exists()
    ledger = home / 'state/fleet-ledger.jsonl'
    records = [json.loads(line) for line in ledger.read_text().splitlines()]
    (evidence / 'retained-fleet-ledger.jsonl').write_text(ledger.read_text())
    assert any(row['event'] == 'task.dispatched' for row in records)
    assert any(row['event'] == 'task.cleaned_up' for row in records)
    (evidence / 'lifecycle-results.json').write_text(json.dumps({
        'task': task, 'launch_generation': original_generation,
        'relaunch_generation': updated['spawn_gen'], 'same_copy': True,
        'copy_removed': True, 'task_retired': True, 'usage_ledger_created': False,
        'model_turn_required': False, 'codex_ui_reached': True,
        'trust_prompt_declined': reached_trust,
        'fleet_events': [row['event'] for row in records]}, indent=2) + '\n')
finally:
    run(['tmux', '-L', 'fm-lab', 'kill-server'], check=False)
    run(['bin/fm-lab-home.sh', 'teardown', str(home)])
