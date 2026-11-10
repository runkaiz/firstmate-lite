from pathlib import Path
import concurrent.futures
import json
import os
import selectors
import shutil
import subprocess
import tempfile
import time

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73RFQ2ZN4FRRV48HJA6BDRH')
EVIDENCE = Path('/home/runkai/.no-mistakes/evidence/01M73RFQ2ZN4FRRV48HJA6BDRH')
scratch = Path(tempfile.mkdtemp(prefix='.sparespeed-check-', dir=ROOT))
transcript = []
proc = None

def record(text):
    transcript.append(text)
    print(text, flush=True)

try:
    home = scratch / 'script-home'
    clean_env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
    clean_env['FM_HOME'] = str(home)
    clean_env['TMPDIR'] = str(scratch)
    fakebin = scratch / 'dependency-monitor'
    fakebin.mkdir()
    quota_calls = scratch / 'quota-calls'
    quota = fakebin / 'quota-axi'
    quota.write_text('#!/bin/sh\nprintf called >> "$QUOTA_MONITOR"\nexit 99\n')
    quota.chmod(0o755)
    clean_env.update(PATH=str(fakebin) + os.pathsep + os.environ['PATH'], QUOTA_MONITOR=str(quota_calls))

    def run(action=(), overrides=None, expected=0):
        env = dict(clean_env)
        if overrides:
            for key, value in overrides.items():
                if value is None:
                    env.pop(key, None)
                else:
                    env[key] = str(value)
        result = subprocess.run(['bash', 'bin/fm-sparespeed.sh', *action], env=env, capture_output=True, text=True)
        record('$ bash bin/fm-sparespeed.sh ' + ' '.join(action) + '\n' + result.stdout + result.stderr + f'exit={result.returncode}')
        assert result.returncode == expected
        return result

    assert run().stdout == 'WORKER FAST MODE: off\n'
    assert not home.exists(), 'status created a home/config directory'
    record('Observed initial status leaves the absent home and config absent.')
    assert run(('on',)).stdout == 'WORKER FAST MODE: on\n'
    flag = home / 'config/worker-fast-mode'
    assert flag.is_file()
    flag.write_text('legacy-presence-file\n')
    before = flag.stat().st_mtime_ns
    for args in [('on',), (), ('status',), ('',)]:
        assert run(args).stdout == 'WORKER FAST MODE: on\n'
        assert flag.read_text() == 'legacy-presence-file\n'
        assert flag.stat().st_mtime_ns == before
    record('Existing presence file contents and modification time survive on, bare, empty-action and status calls.')
    for args in [('maybe',), ('on', 'gpt-6'), ('off', 'gpt-6'), ('status', 'gpt-6')]:
        run(args, expected=2)
        assert flag.read_text() == 'legacy-presence-file\n'
    assert run(('off',)).stdout == 'WORKER FAST MODE: off\n'
    assert not flag.exists()
    assert run(('off',)).stdout == 'WORKER FAST MODE: off\n'
    assert run(('status',)).stdout == 'WORKER FAST MODE: off\n'
    with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
        results = list(pool.map(lambda _: subprocess.run(['bash', 'bin/fm-sparespeed.sh', 'on'], env=clean_env, capture_output=True, text=True), range(24)))
    assert all(r.returncode == 0 and r.stdout == 'WORKER FAST MODE: on\n' for r in results)
    assert flag.is_file() and flag.read_bytes() == b''
    record('24 concurrent on calls each returned WORKER FAST MODE: on and exit=0. One empty presence file persisted.')
    run(('off',))

    override = scratch / 'relocated config'
    assert run(('on',), {'FM_CONFIG_OVERRIDE': override}).stdout == 'WORKER FAST MODE: on\n'
    assert (override / 'worker-fast-mode').is_file() and not flag.exists()
    run(('off',), {'FM_CONFIG_OVERRIDE': override})
    root_override = scratch / 'root fallback'
    run(('on',), {'FM_HOME': None, 'FM_ROOT_OVERRIDE': root_override})
    assert (root_override / 'config/worker-fast-mode').is_file() and not flag.exists()
    run(('off',), {'FM_HOME': None, 'FM_ROOT_OVERRIDE': root_override})
    assert not quota_calls.exists(), 'toggle/status invoked quota-axi'
    record('FM_CONFIG_OVERRIDE and FM_ROOT_OVERRIDE persisted only their isolated flags. No action called the monitored quota-axi dependency.')

    baseline = subprocess.run(['bash', 'tests/fm-quota-choose.test.sh'], env=clean_env, capture_output=True, text=True)
    (EVIDENCE / 'sparespeed-targeted-test.log').write_text(baseline.stdout + baseline.stderr)
    assert baseline.returncode == 0, baseline.stdout + baseline.stderr
    record('Targeted existing tests/fm-quota-choose.test.sh completed successfully, including its executable sparespeed cases.')

    lab = scratch / 'pi-home'
    subprocess.run(['bash', 'bin/fm-lab-home.sh', 'create', str(lab)], check=True, capture_output=True)
    agent = scratch / 'pi-agent'
    agent.mkdir()
    os_home = scratch / 'os-home'
    os_home.mkdir()
    event_file = scratch / 'routing-events.jsonl'
    probe = scratch / 'routing-observer.ts'
    probe.write_text('''import { appendFileSync, writeFileSync } from "node:fs";
export default function(pi) {
  pi.on("session_start", () => {
    writeFileSync(`${process.env.FM_HOME}/state/.lock`, `${process.pid}\\n`);
    appendFileSync(process.env.FM_ROUTING_LOG, JSON.stringify({type:"ready",pid:process.pid})+"\\n");
  });
  pi.on("input", event => {
    appendFileSync(process.env.FM_ROUTING_LOG, JSON.stringify({type:"input",...event})+"\\n");
    return {action:"handled"};
  });
}
''')
    env = {k:v for k,v in os.environ.items() if not k.startswith('FM_')}
    env.update(HOME=str(os_home), XDG_CONFIG_HOME=str(os_home / '.config'), XDG_DATA_HOME=str(os_home / '.local/share'), FM_HOME=str(lab), PI_CODING_AGENT_DIR=str(agent), PI_OFFLINE='1', PI_TELEMETRY='0', FM_ROUTING_LOG=str(event_file))
    command = ['pi', '--mode', 'rpc', '--offline', '--no-mcp', '--no-extensions', '--no-context-files', '--no-prompt-templates', '--no-session', '--no-tools', '--approve', '-e', str(ROOT / '.pi/extensions/fm-stow.ts'), '-e', str(probe), '--skill', str(ROOT / '.agents/skills/sparespeed/SKILL.md')]
    record('Started installed Pi RPC with the real fm-stow extension, isolated agent/home directories, and an input observer that stops delivery at the model boundary.')
    proc = subprocess.Popen(command, env=env, stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, text=True, bufsize=1)
    selector = selectors.DefaultSelector()
    selector.register(proc.stdout, selectors.EVENT_READ)
    rpc_lines = []
    rpc_buffer = ''
    def drain(seconds):
        global rpc_buffer
        deadline = time.monotonic() + seconds
        while time.monotonic() < deadline:
            for key, _ in selector.select(0.05):
                chunk = os.read(key.fileobj.fileno(), 65536)
                if chunk:
                    rpc_buffer += chunk.decode()
                    while '\n' in rpc_buffer:
                        line, rpc_buffer = rpc_buffer.split('\n', 1)
                        rpc_lines.append(line + '\n')
                elif proc.poll() is not None:
                    raise AssertionError('Pi exited early: ' + ''.join(rpc_lines))
    def events():
        return [json.loads(line) for line in event_file.read_text().splitlines()] if event_file.exists() else []
    drain(3)
    assert events()[0]['type'] == 'ready', ''.join(rpc_lines)
    owner_pid = events()[0]['pid']
    proc.stdin.write(json.dumps({'type':'get_commands', 'id':'catalog'}) + '\n')
    proc.stdin.flush()
    drain(0.8)
    catalogs = [json.loads(line) for line in rpc_lines if json.loads(line).get('id') == 'catalog']
    assert catalogs and catalogs[0].get('success'), catalogs
    commands = catalogs[0]['data']['commands']
    catalog_sources = sorted({c.get('sourceInfo', {}).get('baseDir', '') for c in commands})
    record('Final isolated Pi catalog sources ' + json.dumps(catalog_sources))
    assert all(not path or '/01M73RFQ2ZN4FRRV48HJA6BDRH/' in path for path in catalog_sources), catalog_sources
    relevant = [c for c in commands if c['name'] in ['sparespeed', 'skill:sparespeed', 'fastmode', 'skill:fastmode']]
    record('Installed Pi command catalog ' + json.dumps(relevant))
    assert any(c['name'] == 'sparespeed' and c['source'] == 'extension' for c in relevant), relevant
    assert any(c['name'] == 'skill:sparespeed' and c['source'] == 'skill' for c in relevant), relevant
    assert all('fastmode' not in c['name'] for c in relevant), relevant
    request_id = 0
    def prompt(text, expected_text=None, notice=None):
        global request_id
        before = len(events())
        before_rpc = len(rpc_lines)
        request_id += 1
        record('Pi user input ' + repr(text))
        proc.stdin.write(json.dumps({'type':'prompt', 'id':str(request_id), 'message':text}) + '\n')
        proc.stdin.flush()
        drain(0.8)
        emitted = events()[before:]
        if expected_text is not None:
            assert len(emitted) == 1 and emitted[0]['text'] == expected_text and emitted[0]['source'] == 'extension', emitted
            record('Pi emitted ' + json.dumps(emitted[0]))
        else:
            assert emitted == [], emitted
        received = [json.loads(line) for line in rpc_lines[before_rpc:]]
        assert any(r.get('id') == str(request_id) and r.get('success') for r in received), received
        if notice:
            matches = [r for r in received if r.get('method') == 'notify' and r.get('message') == notice]
            assert matches, received
            record('Pi notification ' + matches[0]['message'])
    for action in ['', 'on', 'off', 'status', '  on  ']:
        prompt('/sparespeed' + (' ' + action if action else ''), '/skill:sparespeed ' + action.strip())
    for action in ['maybe', 'on gpt-6', 'off gpt-6', 'status gpt-6']:
        prompt('/sparespeed ' + action, notice='Usage: /sparespeed [on|off|status]')
    (lab / 'state/.lock').write_text('1\n')
    prompt('/sparespeed on', notice='/sparespeed requires the owning Firstmate session.')
    (lab / 'state/.lock').write_text(str(owner_pid) + '\n')
    prompt('/sparespeed status', '/skill:sparespeed status')
    for action in ['', 'on', 'off', 'status']:
        prompt('/proactive' + (' ' + action if action else ''), '/skill:proactive ' + action)
    (EVIDENCE / 'sparespeed-pi-rpc.jsonl').write_text(''.join(rpc_lines))
    (EVIDENCE / 'sparespeed-pi-input-events.jsonl').write_text(event_file.read_text())
    record('Real Pi routed every supported sparespeed action, rejected invalid arguments and a foreign owner, recovered when ownership returned, and preserved proactive routing.')
    record('Model-backed skill execution was excluded under the recorded validation-scope decision. The actual skill-owned script was exercised separately above.')
finally:
    if proc is not None and proc.poll() is None:
        proc.terminate()
        try:
            proc.wait(timeout=5)
        except subprocess.TimeoutExpired:
            proc.kill()
            proc.wait()
    shutil.rmtree(scratch)
    record('Removed all disposable homes, agent state, monitors, and test-generated files from the worktree.')
    (EVIDENCE / 'sparespeed-live-transcript.log').write_text('\n\n'.join(transcript) + '\n')
