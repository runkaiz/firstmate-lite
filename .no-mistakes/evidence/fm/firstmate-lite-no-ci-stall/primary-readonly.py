import os
from pathlib import Path
import subprocess
import time

root = Path.cwd()
lab = root / '.l'
evidence = Path('/home/runkai/.no-mistakes/evidence/01M6HTF41B08PS6PG97VZ5PSAY/primary-readonly.txt')
subprocess.run(['bin/fm-lab-home.sh', 'create', '.l'], check=True)
(lab / 'tmux').mkdir()
(lab / 'config/supervision-host').touch()
env = dict(os.environ)
for key in ['NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'FM_ROOT_OVERRIDE',
            'FM_STATE_OVERRIDE', 'FM_DATA_OVERRIDE', 'FM_CONFIG_OVERRIDE', 'FM_PROJECTS_OVERRIDE']:
    env.pop(key, None)
env['TMUX_TMPDIR'] = '.l/tmux'
tmux = ['tmux', '-L', 'fm-lab']
def run(args, **kwargs):
    return subprocess.run(tmux + args, env=env, capture_output=True, text=True, **kwargs)
wake = next(line.split('\\t', 4)[-1] for line in
            Path('/home/runkai/.no-mistakes/evidence/01M6HTF41B08PS6PG97VZ5PSAY/ci-controlled-transcript.txt').read_text().splitlines()
            if line.startswith('179') and 'ci-no-checks:' in line)
prompt = ('Read-only disposable primary evaluation. Read .agents/skills/validation-supervision/SKILL.md, '
          'then handle the following incoming check wake and give the captain-facing response. '
          'Use only Read; do not run startup, shell, tools with side effects, pipeline commands, '
          'project initialization, or external actions. Do not ask permission to read. '
          'This is a lab with an example PR, and your output is the only requested action. '
          'Incoming wake: ' + wake)
try:
    started = run(['new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40',
                   '-c', str(root), '-e', f'FM_HOME={lab}', 'claude', '-p',
                   '--no-session-persistence', '--tools', 'Read', '--allowedTools', 'Read',
                   '--strict-mcp-config', '--output-format', 'text', '--', prompt])
    if started.returncode:
        raise RuntimeError(started.stderr)
    run(['set-window-option', '-t', 'primary', 'remain-on-exit', 'on'], check=True)
    deadline = time.monotonic() + 90
    while time.monotonic() < deadline:
        status = run(['display-message', '-p', '-t', 'primary', '#{pane_dead}'])
        if status.stdout.strip() == '1':
            break
        time.sleep(1)
    capture = run(['capture-pane', '-p', '-S', '-1000', '-t', 'primary'])
    evidence.write_text('Real Claude primary on private fm-lab tmux socket, 120x40 grid.\n'
                        'Read-only print-mode fallback after interactive workspace trust blocked launch.\n'
                        'Input: actual wake captured from controlled CI-monitor test; not a live pipeline.\n'
                        'Prompt:\n' + prompt + '\n\nCLI transcript:\n' + capture.stdout +
                        '\nPane state: ' + status.stdout)
    print(evidence.read_text())
finally:
    run(['kill-server'])
    import shutil
    shutil.rmtree(lab)
