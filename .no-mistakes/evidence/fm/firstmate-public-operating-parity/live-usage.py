import json
import os
from pathlib import Path
import sqlite3
import subprocess
import tempfile

repo = Path.cwd()
with tempfile.TemporaryDirectory(prefix='fm-lab-usage-', dir=repo / '.test-phase/tmp') as tmp:
    root = Path(tmp)
    home = root / 'home'
    for part in ('state', 'config', 'data'):
        (home / part).mkdir(parents=True)
    env = {k: v for k, v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE'))}
    env['FM_HOME'] = str(home)
    for name in ('CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'PI_CODING_AGENT_DIR', 'NM_HOME'):
        path = root / name
        path.mkdir()
        env[name] = str(path)
    index = sqlite3.connect(root / 'CODEX_HOME/state_5.sqlite')
    index.execute('create table threads(id text primary key, rollout_path text, cwd text)')
    store = home / 'data/usage-ledger'
    auto = repo / 'bin/fm-usage-auto.py'
    ledger = repo / 'bin/fm-usage-ledger.py'
    secret = 'PRIVATE_PROMPT_AND_TOOL_ARGUMENT_MUST_NEVER_PERSIST'
    when = '2026-10-28T10:00:01Z'

    def command(*args):
        result = subprocess.run(list(map(str, args)), env=env, text=True, capture_output=True)
        print('$', ' '.join(map(str, args)))
        print(result.stdout.strip())
        if result.stderr:
            print(result.stderr.strip())
        assert result.returncode == 0, result.returncode
        assert secret not in result.stdout + result.stderr
        return json.loads(result.stdout) if result.stdout else None

    def usage(amount):
        return dict(type='event_msg', timestamp=when, payload=dict(type='token_count', info=dict(
            total_token_usage=dict(input_tokens=amount, output_tokens=2),
            last_token_usage=dict(input_tokens=amount, output_tokens=2))))

    def session(name, cwd, amount):
        path = root / 'CODEX_HOME' / (name + '.jsonl')
        rows = [dict(type='session_meta', payload=dict(id=name, cwd=str(cwd), timestamp=when)),
                dict(type='turn_context', payload=dict(model='synthetic-model', turn_id=name)),
                dict(type='response_item', payload=dict(type='message', content=[dict(text=secret)])),
                dict(type='response_item', payload=dict(type='function_call', name=secret, arguments=secret)),
                usage(amount)]
        path.write_text(''.join(json.dumps(row) + '\n' for row in rows))
        index.execute('insert into threads values(?,?,?)', (name, str(path), str(cwd)))
        index.commit()
        return path

    def refresh():
        return command('python3', auto, 'refresh', '--force')

    def total():
        data = command('python3', ledger, 'summary', '--db', store / 'usage.sqlite')
        return sum(group['tokens']['input']['reported'] for group in data['groups'])

    native = session('supervisor', home, 11)
    foreign = session('foreign', root / 'unrelated-project', 900)
    originals = {p: p.read_bytes() for p in (native, foreign)}
    print('SCENARIO: default-on discovery selects exact home; foreign activity stays excluded')
    command('bash', repo / 'bin/fm-usage-refresh.sh', '--force')
    status = command('python3', auto, 'status')
    assert status['enabled'] and status['known_sources'] == 1
    assert total() == 11
    assert all(p.read_bytes() == data for p, data in originals.items())
    print('SCENARIO: repeat refresh is incremental and does not double count')
    assert refresh()['bytes_read'] == 0
    assert total() == 11
    print('SCENARIO: a newly created session is discovered without manifest edits')
    newer = session('new-session', home, 17)
    assert refresh()['known_sources'] == 2
    assert total() == 28
    print('SCENARIO: partial records stay uncounted with a coverage gap, then count once complete')
    with newer.open('a') as out:
        out.write(json.dumps(usage(20)))
    assert 'unread_bytes' in refresh()['gaps']
    assert total() == 28
    with newer.open('a') as out:
        out.write('\n')
    refresh()
    assert total() == 31
    assert refresh()['bytes_read'] == 0
    assert total() == 31
    print('SCENARIO: persisted stores omit prompt/tool bodies and have private permissions')
    for file in store.rglob('*'):
        if file.is_file():
            assert secret.encode() not in file.read_bytes(), file
            assert file.stat().st_mode & 0o077 == 0, file
            print('private sanitized file:', file.name, oct(file.stat().st_mode & 0o777))
    db = sqlite3.connect(store / 'usage.sqlite')
    assert secret not in '\n'.join(db.iterdump())
    db.close()
    print('SCENARIO: disable switch reports disabled instead of inventing usage')
    (home / 'config/usage-ledger').write_text('off\n')
    assert refresh()['enabled'] is False
    index.close()
    print('OBSERVED: totals 11 -> 28 -> 31; no duplicate counts, no foreign usage, no retained content')
