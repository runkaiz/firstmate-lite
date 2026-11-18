import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7RER93RQ5FCMJD426B48YQJ')
EVIDENCE = Path('/home/runkai/.no-mistakes/evidence/01M7RER93RQ5FCMJD426B48YQJ')
LAB = ROOT / '.q'
assert not LAB.exists(), 'refusing an existing lab'
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('NO_MISTAKES_GATE', 'TMUX', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND'):
        env.pop(key)
env.update(FM_HOME=str(LAB), XDG_RUNTIME_DIR=str(LAB / 'runtime'), TMUX_TMPDIR=str(LAB / 'tmux'))
env.update(BASH_DEFAULT_TIMEOUT_MS='600000', BASH_MAX_TIMEOUT_MS='600000')

def run(args, **kwargs):
    return subprocess.run(args, cwd=ROOT, env=env, **kwargs)

def tmux(*args, **kwargs):
    return run(['tmux', '-L', 'fm-lab', *args], **kwargs)

def events(path):
    result = []
    for line in path.read_text().splitlines():
        try:
            result.append(json.loads(line))
        except json.JSONDecodeError:
            pass
    return result

holder = None
results = {}
try:
    run(['bin/fm-lab-home.sh', 'create', str(LAB)], check=True)
    (LAB / 'tmux').mkdir()
    (LAB / 'runtime').mkdir()
    (LAB / 'config/supervision-host-off').touch()
    (LAB / 'config/resource-locks').write_text('quiet-probe 1 isolated validation command\n')
    briefs = {}
    for kind, args in [('no-mistakes', ['--mode', 'no-mistakes']), ('direct-PR', ['--mode', 'direct-PR']), ('local-only', ['--mode', 'local-only']), ('scout', ['--scout'])]:
        task = 'quiet-r2-' + kind
        run(['bin/fm-brief.sh', task, 'sample', *args], check=True, stdout=subprocess.DEVNULL)
        brief = (LAB / 'data' / task / 'brief.md').read_text()
        (EVIDENCE / ('r2-emitted-' + kind + '-brief.md')).write_text(brief)
        assert 'on timeout, immediately reissue the same wait with no intervening text and no new paused declaration' in brief
        assert 'with one blocking tool call at the longest timeout your shell tool allows' in brief
        assert 'post no progress or "still waiting" text between waits; report once when the result arrives' in brief
        briefs[kind] = brief
    results['delivery'] = {'result': 'pass', 'modes': list(briefs), 'wait_no_turns_flag': 'absent'}
    lines = briefs['scout'].splitlines()
    begin = next(i for i, line in enumerate(lines) if 'Use `paused: {why}`' in line)
    end = next(i for i, line in enumerate(lines[begin:], begin) if 'Use `blocked:` when' in line) + 1
    status_rules = '\n'.join(lines[begin:end])
    (EVIDENCE / 'r2-consumed-status-rules.txt').write_text(status_rules + '\n')
    commands = {
        'long': '''python3 -c "import hashlib; print(hashlib.pbkdf2_hmac('sha256',b'isolated',b'validation',120000000).hex()); print('LONG_COMMAND_COMPLETE')"''',
        'lock': './bin/fm-resource-lock.sh run quiet-probe -- printf "LOCKED_COMMAND_COMPLETE\\n"',
        'timeout': 'timeout 5s ./bin/fm-resource-lock.sh run quiet-probe -- printf "TIMEOUT_RECOVERY_COMPLETE\\n"',
    }
    for name, command in commands.items():
        ready, release = LAB / 'state/holder-ready', LAB / 'state/holder-release'
        ready.unlink(missing_ok=True)
        release.unlink(missing_ok=True)
        if name in ('lock', 'timeout'):
            holder_code = 'import os,pathlib,time; p=pathlib.Path(os.environ["FM_HOME"])/"state"; (p/"holder-ready").touch(); start=time.monotonic();\nwhile not (p/"holder-release").exists() and time.monotonic()-start<100: time.sleep(.1)'
            holder_log = open(EVIDENCE / ('r2-' + name + '-holder.txt'), 'w')
            holder = subprocess.Popen(['bin/fm-resource-lock.sh', 'run', 'quiet-probe', '--', 'python3', '-c', holder_code], cwd=ROOT, env=env, stdout=holder_log, stderr=holder_log)
            deadline = time.monotonic() + 10
            while not ready.exists():
                assert holder.poll() is None and time.monotonic() < deadline, 'holder did not acquire lock'
                time.sleep(.1)
        retry = ' Retry this exact wrapped command if its timeout expires before it acquires the lock; stop once TIMEOUT_RECOVERY_COMPLETE is printed.' if name == 'timeout' else ''
        prompt = ('This is a disposable development evaluation of emitted worker instructions, not a coding assignment. Execute this one harmless command in the current worktree and report its result: ' + command + retry + '\nThe command may take time to complete. Apply the following status instructions emitted by the real Firstmate brief generator. The status file is ' + str(LAB / 'state' / (name + '.status')) + '. All intentional writes must stay in ' + str(LAB) + '. Do not initialize a pipeline or invoke fleet lifecycle.\n' + status_rules + '\n')
        prompt_path = LAB / (name + '.prompt')
        prompt_path.write_text(prompt)
        (EVIDENCE / ('r2-' + name + '-prompt.txt')).write_text(prompt)
        out = EVIDENCE / ('r2-' + name + '-claude-stream.jsonl')
        err = EVIDENCE / ('r2-' + name + '-claude-stderr.txt')
        out.write_text('')
        err.write_text('')
        cli = ['claude', '-p', '--setting-sources', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}', '--no-session-persistence', '--tools', 'Bash', '--allowedTools', 'Bash', '--system-prompt', 'You are a worker performing an isolated development evaluation. Follow the task instructions. You may only use Bash for the assigned command and its status declaration.', '--output-format', 'stream-json', '--verbose']
        launch = LAB / (name + '.sh')
        launch.write_text('#!/bin/bash\n' + shlex.join(cli) + ' < ' + shlex.quote(str(prompt_path)) + ' > ' + shlex.quote(str(out)) + ' 2> ' + shlex.quote(str(err)) + '\nprintf "CLI_EXIT=%s\\n" "$?" >> ' + shlex.quote(str(err)) + '\nsleep 3\n')
        tmux('new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(ROOT), '-e', 'FM_HOME=' + str(LAB), 'bash ' + shlex.quote(str(launch)), check=True)
        started = time.monotonic()
        first_wait = None
        timed = []
        while time.monotonic() - started < 170:
            es = events(out)
            wait_calls = [b for e in es if e.get('type') == 'assistant' for b in e.get('message', {}).get('content', []) if b.get('type') == 'tool_use' and 'fm-resource-lock.sh run' in b.get('input', {}).get('command', '')]
            if wait_calls and first_wait is None:
                first_wait = time.monotonic()
            timeout_results = [b for e in es if e.get('type') == 'user' for b in e.get('message', {}).get('content', []) if b.get('type') == 'tool_result' and ('124' in str(b.get('content', '')) or e.get('tool_use_result', {}).get('interrupted'))]
            if name == 'lock' and first_wait is not None and time.monotonic() - first_wait >= 20:
                release.touch()
            if name == 'timeout' and len(timeout_results) >= 2:
                release.touch()
            if len(es) > len(timed):
                timed.extend({'received_after_seconds': round(time.monotonic()-started, 2), 'event': e} for e in es[len(timed):])
            if any(e.get('type') == 'result' for e in es):
                break
            if tmux('has-session', '-t', 'primary', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL).returncode:
                break
            time.sleep(.2)
        elapsed = round(time.monotonic() - started, 2)
        with open(EVIDENCE / ('r2-' + name + '-pane.txt'), 'w') as pane:
            tmux('capture-pane', '-p', '-t', 'primary', stdout=pane, stderr=subprocess.DEVNULL)
        tmux('kill-server', stderr=subprocess.DEVNULL)
        if holder is not None:
            release.touch()
            holder.wait(timeout=10)
            holder_log.close()
            holder = None
        state = LAB / 'state' / (name + '.status')
        status = state.read_text() if state.exists() else ''
        (EVIDENCE / ('r2-' + name + '-status.txt')).write_text(status)
        (EVIDENCE / ('r2-' + name + '-timed-events.json')).write_text(json.dumps(timed, indent=2))
        es = events(out)
        transcript = ['Real Claude; disposable marked FM_HOME; private fm-lab tmux server (120x40).', 'Elapsed: ' + str(elapsed) + ' seconds.']
        flat = []
        for event in es:
            if event.get('type') in ('assistant', 'user'):
                for block in event.get('message', {}).get('content', []):
                    if block.get('type') == 'text':
                        transcript.append('ASSISTANT: ' + block['text'])
                        flat.append(('text', block['text']))
                    elif block.get('type') == 'tool_use':
                        transcript.append('TOOL ' + block['name'] + ': ' + json.dumps(block['input']))
                        flat.append(('tool', block['input']))
                    elif block.get('type') == 'tool_result':
                        transcript.append('TOOL RESULT: ' + str(block.get('content', '')))
                        flat.append(('result', str(block.get('content', ''))))
        (EVIDENCE / ('r2-' + name + '-transcript.txt')).write_text('\n\n'.join(transcript) + '\n')
        results[name] = {'elapsed_seconds': elapsed, 'completed': any(e.get('type') == 'result' and not e.get('is_error') for e in es), 'flat': flat, 'status': status, 'forced_timeout_results': len(timeout_results)}
        (EVIDENCE / 'r2-evaluation-results.json').write_text(json.dumps(results, indent=2))
        print(name, elapsed, 'seconds; completed=', results[name]['completed'], 'forced timeouts=', len(timeout_results), flush=True)
finally:
    tmux('kill-server', stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    if holder is not None:
        (LAB / 'state/holder-release').touch()
        try:
            holder.wait(timeout=5)
        except subprocess.TimeoutExpired:
            holder.terminate()
            holder.wait(timeout=5)
    shutil.rmtree(LAB)
    (ROOT / 'tests/.quiet-selected.test.sh').unlink(missing_ok=True)
    print('Disposable home and private socket removed.', flush=True)
