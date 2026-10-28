"""Disposable product walkthrough; real shipped CLI, no replacement product code."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile
import time

ROOT = Path.cwd()
EVIDENCE = Path(__file__).parent
HOME = Path(tempfile.mkdtemp(prefix='fm-lab.', dir=ROOT / '.test-phase-tmp'))
env = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'TMUX'))}
env.update(FM_HOME=str(HOME), HOME=str(HOME), TMPDIR=str(ROOT / '.test-phase-tmp'), PYTHONDONTWRITEBYTECODE='1')
log = (EVIDENCE / 'queue-walkthrough.log').open('w')

def run(command, *args, good=True, extra=None, cwd=None):
    argv = [str(command), *map(str, args)]
    result = subprocess.run(argv, cwd=cwd or ROOT, env=dict(env, **(extra or {})), text=True, capture_output=True, timeout=45)
    log.write('$ ' + shlex.join(argv).replace(str(ROOT), '$WORKTREE').replace(str(HOME), '$LAB') + '\n')
    log.write(result.stdout + result.stderr + f'[exit {result.returncode}]\n\n')
    log.flush()
    assert (result.returncode == 0) == good, result.stdout + result.stderr
    return result.stdout + result.stderr

def q(*args, **kw):
    return run(ROOT / 'bin/fm-queue.sh', *args, **kw)

def task(identifier):
    return json.loads(q('show', identifier, '--json'))['task']

def ready():
    return [x['id'] for x in json.loads(q('ready', '--json'))['tasks']]

def section(name):
    log.write('\n=== ' + name + ' ===\n')
    print(name, flush=True)

try:
    run(ROOT / 'bin/fm-lab-home.sh', 'create', HOME)
    (HOME / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
    section('Capture, authorize, and resist retained-context bypasses')
    q('add', 'idea', 'Potential improvement', '--idea', '--body', 'Unapproved proposal')
    q('add', 'outcome', 'Durable outcome', '--outcome', '--body', 'Related task: idea; no dependency implied')
    q('update', 'idea', '--priority', '0')
    for identifier in ('idea', 'outcome'):
        q('start', identifier, good=False)
        q('unhold', identifier, good=False)
        q('update', identifier, '--kind', 'task', good=False)
    assert ready() == []
    q('authorize', 'idea', good=False)
    q('authorize', 'outcome', '--body', 'Try to execute context', good=False)
    q('authorize', 'idea', '--body', 'Approved: implement only this small improvement')
    assert ready() == ['idea']
    q('add', 'next', 'Dependent work', '--blocked-by', 'idea')
    q('start', 'next', good=False)

    section('Unicode follow-up history, archived dependency, and same-ID reopening')
    q('update', 'idea', '--body', 'Invalid control byte\v', good=False)
    body = 'Original α\u2028middle\u2029end\u0085tail\nArtifact context remains.'
    q('update', 'idea', '--body', body)
    assert task('idea')['body'] == body
    q('update', 'idea', '--body', 'Revised scope under the same identity')
    history = (HOME / 'data/note-archive.md').read_text()
    assert body.split('\n')[0] in history and 'Artifact context remains.' in history
    q('done', 'idea', '--report', 'data/idea/report.md', '--no-prune')
    q('prune', '--keep', '0')
    assert 'next' in ready()
    snapshot = run(ROOT / 'bin/fm-fleet-snapshot.sh', '--json')
    (EVIDENCE / 'fleet-snapshot.json').write_text(snapshot)
    rows = json.loads(snapshot)['backlog']['records']
    row = next(x for x in rows if x.get('id') == 'next')
    assert row['unresolved_blocker_ids'] == [], row
    archived = task('idea')
    assert archived['archived'] and 'data/idea/report.md' in archived['links']
    q('add', 'idea', 'Accidental ID reuse', good=False)
    q('reopen', 'idea')
    reopened = task('idea')
    assert reopened['body'] == archived['body'] and reopened['links'] == archived['links']
    assert not reopened['archived'] and reopened['state'] == 'queued'
    assert 'next' not in ready()
    (EVIDENCE / 'note-history.md').write_bytes((HOME / 'data/note-archive.md').read_bytes())

    section('Real answer owner preserves opaque reasons and distinguishes release from completion')
    hold = ROOT / 'bin/fm-captain-hold.sh'
    reason = 'Choose scope (not a dependency)\nLiteral (hold-kind: parked) text'
    run(hold, 'hold', 'idea', '--reason', reason, '--until', '2000-01-01')
    assert 'idea' not in ready()
    q('show', 'idea')
    decision = HOME / 'answer.txt'
    decision.write_text('Use the existing release.\n')
    run(hold, 'answer', 'idea', '--decision-file', decision, '--release')
    assert task('idea')['state'] == 'queued' and 'idea' in ready()
    assert 'Use the existing release.' in task('idea')['body']
    run(hold, 'hold', 'question', '--title', 'Choose the final scope', '--reason', 'A genuine question')
    q('add', 'parked-idea', 'Retained idea', '--idea')
    section('Real away-return brief excludes parked ideas and outcomes')
    (HOME / 'state/.afk').write_text(f'away\n{int(time.time())}\n')
    brief = run(ROOT / 'bin/fm-afk-return.sh', 'check')
    (EVIDENCE / 'away-return.txt').write_text(brief)
    waiting = brief.split('Waiting on you:', 1)[1].split('Tried and failed', 1)[0]
    assert 'question' in waiting and 'parked-idea' not in waiting and 'outcome' not in waiting
    run(hold, 'answer', 'question', '--decision-file', decision)
    assert task('question')['state'] == 'done'

    section('Compatible backup preserves bytes and caller-relative destination')
    before = {p.name: p.read_bytes() for p in (HOME / 'data').iterdir() if p.is_file()}
    q('migrate', '--dry-run')
    caller = HOME / 'caller'
    caller.mkdir()
    q('migrate', '--backup-dir', './backup', cwd=caller)
    assert (caller / 'backup').is_dir() and not (HOME / 'backup').exists()
    assert all(p.read_bytes() == before[p.name] for p in (HOME / 'data').iterdir() if p.is_file())
    q('migrate', '--backup-dir=./backup', cwd=caller, good=False)
    log.write('Backup files: ' + ', '.join(sorted(x.name for x in (caller / 'backup').iterdir())) + '\n')

    section('Legacy backend selection is read-only, actionable, and never a second store')
    (HOME / '.tasks.toml').write_text('[markdown]\npath = "data/backlog.md"\n')
    (HOME / '.tasks-axi').mkdir()
    config = HOME / 'selection.toml'
    config.write_text('backend = "markdown"\n')
    (HOME / '.tasks-axi/config.toml').symlink_to(config)
    q('list')
    config.write_text('backend = "beads"\n[beads]\npassword = "do-not-expose-secret"\n')
    before = {p.name: p.read_bytes() for p in (HOME / 'data').iterdir() if p.is_file()}
    refusal = q('add', 'forbidden', 'Must not create', good=False)
    assert '.tasks-axi/config.toml' in refusal and 'Markdown only' in refusal and 'do-not-expose-secret' not in refusal
    assert all(p.read_bytes() == before[p.name] for p in (HOME / 'data').iterdir() if p.is_file())
    q('list', extra={'FM_QUEUE_BACKEND': 'markdown'})
    run(ROOT / 'bin/fm-queue.py', 'list', '--file', HOME / 'data/backlog.md', '--backend', 'markdown', extra={'FM_QUEUE_BACKEND': 'beads'})
    q('list', '--backend', 'markdown', extra={'FM_QUEUE_BACKEND': 'beads'})
    section('All walkthrough assertions passed')
finally:
    shutil.rmtree(HOME)
    log.write('Disposable home removed.\n')
    log.close()
