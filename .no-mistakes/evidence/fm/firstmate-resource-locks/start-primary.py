import os
from pathlib import Path
import shlex
import subprocess

root = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ')
env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') or k in ['NO_MISTAKES_GATE', 'CLAUDECODE', 'TMUX'])}
env['TMUX_TMPDIR'] = str(root / 'l/tmux')
args = ['tmux', '-L', 'fm-lab', '-f', '/dev/null', 'new-session', '-d', '-s', 'primary', '-x', '140', '-y', '40', '-c', str(root), '-e', 'FM_HOME=' + str(root / 'l'), 'claude', '-p', '--no-session-persistence', '--setting-sources', '', '--strict-mcp-config', '--tools', 'Bash', '--allowedTools', 'Bash', '--system-prompt', 'You are a disposable live-test primary. Use Bash once to execute the exact script requested. Do not read other files, modify configuration, delegate, or do other work. Report the script exit code.', 'Run bash .test-live/spawn-scenario.sh from the current directory and report its exit code.']
print(shlex.join(args))
subprocess.run(args, env=env, check=True)
for option, value in [('remain-on-exit', 'on'), ('default-command', '/bin/bash --noprofile --norc')]:
    subprocess.run(['tmux', '-L', 'fm-lab', 'set-option', '-g', option, value], env=env, check=True)
