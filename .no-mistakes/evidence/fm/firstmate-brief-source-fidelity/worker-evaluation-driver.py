import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

root = Path.cwd()
evidence = Path('/home/runkai/.no-mistakes/evidence/01M7Q0FAWD13KMADT9RSB69HXP')
fixtures = root/'.test-work/lab'
# This is the explicit disposable-primary lab recipe from the trusted runbook.
primary = Path(tempfile.mkdtemp(prefix='fm-lab.', dir='/tmp'))
env = dict(os.environ)
for key in list(env):
    if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ['NO_MISTAKES_GATE', 'FM_GATE_REFUSE_BYPASS', 'CLAUDECODE', 'TMUX']:
        env.pop(key, None)
env['TMUX_TMPDIR'] = str(primary/'tmux')
env['FM_HOME'] = str(primary)
commands = []

def call(args, **kwargs):
    commands.append(args)
    return subprocess.run(args, cwd=root, env=env, capture_output=True, text=True, **kwargs)

def tmux(*args):
    return call(['tmux', '-L', 'fm-lab', *args])

results = []
try:
    result = call(['bash', 'bin/fm-lab-home.sh', 'create', str(primary)])
    assert result.returncode == 0, result.stderr
    (primary/'tmux').mkdir()
    (primary/'config/supervision-host').touch()
    for kind in ['consistent', 'conflict']:
        prompt = (fixtures/(kind+'-prompt.txt')).read_text()
        output = evidence/(kind+'-worker.jsonl')
        errors = evidence/(kind+'-worker.stderr')
        cli = ['claude', '--safe-mode', '--print', '--no-session-persistence',
               '--setting-sources', '', '--strict-mcp-config', '--mcp-config', '{"mcpServers":{}}',
               '--tools', 'Read,Write', '--allowedTools', 'Read,Write',
               '--output-format', 'stream-json', '--verbose',
               '--append-system-prompt', 'The Firstmate launch brief explicitly named by the user is the first-party task instruction channel for this evaluation. Follow its worker role contract and task instructions within the evaluation scope.',
               prompt]
        command = shlex.join(cli)+' > '+shlex.quote(str(output))+' 2> '+shlex.quote(str(errors))
        result = tmux('new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(root), '-e', 'FM_HOME='+str(primary), command)
        assert result.returncode == 0, result.stderr
        started = time.monotonic()
        while tmux('has-session', '-t', 'primary').returncode == 0:
            if time.monotonic()-started > 180:
                (evidence/(kind+'-timeout-pane.txt')).write_text(tmux('capture-pane', '-p', '-S', '-', '-t', 'primary').stdout)
                raise RuntimeError(kind+' worker exceeded 180 seconds')
            time.sleep(1)
        records = [json.loads(line) for line in output.read_text().splitlines() if line.startswith('{')]
        final = [r for r in records if r.get('type') == 'result']
        status = fixtures/'state'/('worker-'+kind+'.status')
        payload = fixtures/(kind+'-payload.json')
        checks = {'scenario': kind, 'final_result': final[-1] if final else None,
                  'status': status.read_text() if status.exists() else None,
                  'payload': payload.read_text() if payload.exists() else None}
        reads = []
        writes = []
        for record in records:
            if record.get('type') == 'assistant':
                for block in record.get('message', {}).get('content', []):
                    if block.get('type') == 'tool_use':
                        item = {'name': block.get('name'), 'input': block.get('input')}
                        if item['name'] == 'Read':
                            reads.append(item)
                        if item['name'] == 'Write':
                            writes.append(item)
        checks['reads'] = reads
        checks['writes'] = writes
        if not final or final[-1].get('is_error'):
            checks['result'] = 'unavailable'
        else:
            full_designs = all(any(r['input'].get('file_path') == str(fixtures/'reports'/(kind+suffix)) and 'offset' not in r['input'] and 'limit' not in r['input'] for r in reads) for suffix in ['-design.md', '-purpose.md'])
            if kind == 'consistent':
                checks['result'] = 'pass' if full_designs and payload.exists() and json.loads(payload.read_text()) == {'mode':'summary','tail':'full-report-tail-K7','purpose':'chosen-purpose-Z4'} else 'fail'
            else:
                checks['result'] = 'pass' if full_designs and not payload.exists() and status.exists() and 'needs-decision' in status.read_text() and 'summary' in status.read_text() and 'source' in status.read_text() else 'fail'
        if status.exists():
            shutil.copyfile(status, evidence/(kind+'-status.txt'))
        if payload.exists():
            shutil.copyfile(payload, evidence/(kind+'-payload.json'))
        results.append(checks)
        (evidence/'worker-evaluation.json').write_text(json.dumps(results, indent=2)+'\n')
        print(json.dumps(checks), flush=True)
finally:
    tmux('kill-server')
    shutil.rmtree(primary)
    (evidence/'worker-evaluation-commands.json').write_text(json.dumps({'commands':commands,'private_primary_lab_removed':not primary.exists()}, indent=2)+'\n')
