import hashlib
import json
import os
from pathlib import Path
import subprocess

root = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73FXDW27CZ6BKZQR9ZYJN1V')
evidence = Path('/home/runkai/.no-mistakes/evidence/01M73FXDW27CZ6BKZQR9ZYJN1V')
base = root / '.test-usage-removal'
env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
env.pop('FM_GATE_REFUSE_BYPASS', None)
env['DISABLE_AUTOUPDATER'] = '1'

def run(args, home, name, timeout=150, **extra):
    current = dict(env, FM_HOME=str(home), **extra)
    result = subprocess.run(args, env=current, text=True, stdout=subprocess.PIPE,
                            stderr=subprocess.STDOUT, timeout=timeout)
    (evidence / name).write_text('$ ' + ' '.join(args) + '\n' + result.stdout + '\nexit=' + str(result.returncode) + '\n')
    assert result.returncode == 0, (args, result.stdout)
    return result.stdout

def snapshot(path):
    return {str(p.relative_to(path)): {'sha256': hashlib.sha256(p.read_bytes()).hexdigest(),
                                      'mtime_ns': p.stat().st_mtime_ns}
            for p in path.rglob('*') if p.is_file()}

results = []
for case in ('fresh', 'legacy'):
    home = base / case
    if not home.exists():
        run(['bin/fm-lab-home.sh', 'create', str(home)], home, case + '-create.txt')
    if case == 'legacy':
        ledger = home / 'data/usage-ledger'
        ledger.mkdir()
        (ledger / 'status.json').write_text('{"old":"keep verbatim", "invalid":')
        (ledger / 'events.jsonl').write_text('old record with private historical bytes\n')
        (home / 'config/usage-ledger').write_text('on\n')
        before = snapshot(ledger)
        output = run(['bin/fm-session-start.sh'], home, case + '-startup.txt')
    else:
        output = run(['bin/fm-session-start.sh'], home, case + '-startup.txt')
    assert 'lock acquired:' in output
    assert 'LOCAL USAGE' not in output
    assert 'fm-usage' not in output
    assert 'SESSION START COMPLETE' in output or 'NEXT STEP' in output
    (home / 'state/ledger-removal.status').write_text('done: usage-removal live monitoring signal\n')
    output = run(['bin/fm-watch.sh'], home, case + '-monitoring.txt', timeout=40,
                 FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
    assert 'signal:' in output and 'ledger-removal.status' in output
    run(['bin/fm-session-start.sh', '--reemit'], home, case + '-reemit.txt')
    run(['bin/fm-startup-network.sh', 'wait', '30'], home, case + '-network.txt', timeout=40)
    if case == 'legacy':
        after = snapshot(ledger)
        assert before == after
        assert (home / 'config/usage-ledger').read_text() == 'on\n'
        results.append({'scenario': 'Obsolete opt-in and corrupt historical ledger survive startup, monitoring, and reemit',
                        'before': before, 'after': after})
    else:
        assert not (home / 'data/usage-ledger').exists()
        results.append({'scenario': 'Fresh startup, monitoring, and reemit create no usage ledger',
                        'data_files': sorted(str(p.relative_to(home)) for p in (home / 'data').rglob('*'))})

home = base / 'fresh'
quota = {'schemaVersion': 5, 'generatedAt': '2026-11-10T20:00:00Z', 'providers': []}
for provider, percent in [('codex', 0), ('claude', 65)]:
    quota['providers'].append({'provider': provider, 'windows': [], 'quotaSemantics': {
        'status': 'known', 'effectiveAvailability': [{'scope': 'all_models', 'status': 'known',
        'effectivePercentRemaining': percent, 'runway': {'status': 'exhausted_now' if percent == 0 else 'projected_exhaustion'}}]}})
quota_path = base / 'quota.json'
quota_path.write_text(json.dumps(quota))
output = run(['bin/fm-quota-choose.sh', '--snapshot', str(quota_path), '--candidate', 'codex:lab-model',
              '--candidate', 'claude:lab-model'], home, 'quota-selection.txt')
assert output.strip() == 'claude lab-model'
quota['providers'][1]['quotaSemantics']['effectiveAvailability'][0].update(
    effectivePercentRemaining=0, runway={'status': 'exhausted_now'})
quota_path.write_text(json.dumps(quota))
result = subprocess.run(['bin/fm-quota-choose.sh', '--snapshot', str(quota_path),
                         '--candidate', 'codex:lab-model', '--candidate', 'claude:lab-model'],
                        env=dict(env, FM_HOME=str(home)), capture_output=True, text=True)
(evidence / 'quota-all-exhausted.txt').write_text(result.stdout + result.stderr + '\nexit=' + str(result.returncode) + '\n')
assert result.returncode == 1 and result.stdout.strip() == 'none'
results.append({'scenario': 'Quota selection skips an exhausted candidate and refuses all-exhausted candidates without a usage ledger',
                'selected': output.strip(), 'all_exhausted': result.stdout.strip(), 'all_exhausted_exit': result.returncode})
(evidence / 'live-results.json').write_text(json.dumps(results, indent=2) + '\n')
print(json.dumps(results, indent=2))
