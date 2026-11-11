"""Disposable end-to-end exercise of the shipped shell wrapper; no product doubles."""
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import tempfile

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M74QH32GCR2CZ6HW0N75KFEK')
EVIDENCE = Path('/home/runkai/.no-mistakes/evidence/01M74QH32GCR2CZ6HW0N75KFEK')
results = []

def home(parent, name):
    value = parent / name
    (value / 'data').mkdir(parents=True)
    (value / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
    return value

def call(lab, *args, expected=0, extra=None):
    environment = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'NO_MISTAKES_'))}
    environment.update(FM_HOME=str(lab), HOME=str(lab), TMPDIR=str(ROOT / '.test-notes-live'))
    environment.update(extra or {})
    command = ['bash', str(ROOT / 'bin/fm-queue.sh'), *args]
    print('\nFM_HOME=' + str(lab) + ' ' + shlex.join(command), flush=True)
    run = subprocess.run(command, cwd=ROOT, env=environment, text=True, capture_output=True, timeout=30)
    print(run.stdout, end='')
    print(run.stderr, end='')
    print('exit:', run.returncode, flush=True)
    assert run.returncode == expected, (args, run.returncode, expected)
    return run.stdout + run.stderr

def task(lab, identifier):
    return json.loads(call(lab, 'show', identifier, '--json'))['task']

def state(lab):
    return {str(p.relative_to(lab)): p.read_bytes() for p in lab.rglob('*') if p.is_file() and not p.is_symlink()}

def passed(name):
    results.append({'name': name, 'result': 'pass', 'live': True})
    print('\nPROVEN:', name, flush=True)

with tempfile.TemporaryDirectory(dir=ROOT / '.test-notes-live') as temporary:
    parent = Path(temporary)
    lab = home(parent, 'notes')
    source = lab / 'input.md'
    original = '## Accepted intent\n' + 'Long scope with Unicode 雪 and indentation\n' * 12 + '\n- [ ] nested - This is note text\n'
    source.write_text(original)
    call(lab, 'add', 'delivery', 'Deliver accepted work', '--kind', 'ship', '--repo', 'demo', '--body-file', str(source))
    backlog = lab / 'data/backlog.md'
    notes = lab / 'data/delivery/notes.md'
    assert notes.read_text() == original
    assert 'Long scope' not in backlog.read_text()
    assert '  notes: delivery/notes.md\n' in backlog.read_text()
    print('\nPERSISTED BACKLOG:\n' + backlog.read_text())
    assert 'delivery/notes.md' in call(lab, 'list')
    rendered = call(lab, 'show', 'delivery', '--full')
    rendered_body = next(line.removeprefix('  body: ') for line in rendered.splitlines() if line.startswith('  body: '))
    assert json.loads(rendered_body) == original
    assert task(lab, 'delivery')['body'] == original
    assert 'Long scope' in json.loads(call(lab, 'snapshot'))['text']
    source.write_text('Replacement intent\n\nRetained detail\n')
    call(lab, 'update', 'delivery', '--body-file', str(source))
    assert notes.read_text() == source.read_text()
    history = lab / 'data/note-archive.md'
    assert '  Long scope with Unicode 雪 and indentation\n' in history.read_text()
    print('\nPERSISTED NOTE HISTORY:\n' + history.read_text())
    call(lab, 'start', 'delivery')
    assert task(lab, 'delivery')['state'] == 'in_flight'
    call(lab, 'done', 'delivery', '--keep', '0', '--note', 'Validated delivery')
    completed = task(lab, 'delivery')['body']
    assert 'Retained detail' in completed and 'Validated delivery' in completed
    call(lab, 'reopen', 'delivery')
    assert task(lab, 'delivery')['body'] == completed
    assert notes.read_text() == completed
    passed('Long notes remain outside the compact queue, readable through the CLI, preserved on replacement and archive/reopen')

    call(lab, 'update', 'delivery', '--body', 'x' * 240)
    before = state(lab)
    for flag in ('--body', '--note'):
        for value in ('x' * 241, 'First\nSecond', 'First\rSecond'):
            output = call(lab, 'update', 'delivery', flag, value, expected=1)
            assert 'one short line' in output and '--body-file' in output
            assert state(lab) == before
    passed('Oversized and multiline inline body/note inputs refuse with file guidance and no persisted changes')

    migration = home(parent, 'migration')
    queue = migration / 'data/backlog.md'
    migrated_notes = migration / 'data/migrated/notes.md'
    migrated_notes.parent.mkdir()
    raw = 'Prior\r\n  Indented 雪\r\nFinal\rTail\u2028detail\r\n'.encode()
    migrated_notes.write_bytes(raw)
    old = b'## Queued\r\n- [ ] migrated - Accepted work\r\n  Inline scope\r\n'
    queue.write_bytes(old)
    call(migration, 'migrate-notes', '--dry-run')
    assert queue.read_bytes() == old and migrated_notes.read_bytes() == raw
    call(migration, 'migrate-notes')
    expected = 'Prior\n  Indented 雪\nFinal\nTail\u2028detail\n\n\nInline scope'
    assert task(migration, 'migrated')['body'] == expected
    assert migrated_notes.read_bytes() == expected.encode()
    archived_notes = migration / 'data/note-archive.md'
    assert b'  Prior\r\n    Indented ' in archived_notes.read_bytes()
    assert old.split(b'\r\n', 1)[1] in archived_notes.read_bytes()
    before = state(migration)
    assert json.loads(call(migration, 'migrate-notes'))['migrated'] == []
    assert state(migration) == before
    print('\nRAW HISTORY BYTE REPRESENTATION:', repr(archived_notes.read_bytes()))
    passed('Migration merges existing CRLF notes with inline notes, archives original bytes, leaves dry-run unchanged and repeats without changes')
    call(migration, 'done', 'migrated', '--no-prune')
    call(migration, 'prune', '--keep', '0')
    assert task(migration, 'migrated')['body'] == expected
    call(migration, 'reopen', 'migrated')
    assert task(migration, 'migrated')['body'] == expected
    replacement = migration / 'replacement.md'
    replacement.write_bytes(b'Replacement\r\nNext\rStep\r\n')
    call(migration, 'update', 'migrated', '--body-file', str(replacement))
    assert migrated_notes.read_bytes() == b'Replacement\nNext\nStep\n'
    assert b'  Replacement\r\n  Next\rStep\r\n' in archived_notes.read_bytes()
    migrated_notes.write_bytes(b'External\r\nCurrent scope\r\n')
    assert task(migration, 'migrated')['body'] == 'External\nCurrent scope\n'
    assert migrated_notes.read_bytes() == b'External\r\nCurrent scope\r\n'
    call(migration, 'done', 'migrated', '--keep', '0')
    call(migration, 'reopen', 'migrated')
    assert task(migration, 'migrated')['body'] == 'External\nCurrent scope\n'
    assert b'  External\r\n  Current scope\r\n' in archived_notes.read_bytes()
    passed('Migrated, imported and externally edited CRLF notes complete, prune, replace and reopen with normalized text and raw history retained')

    recovery = home(parent, 'recovery')
    (recovery / 'data/backlog.md').write_text('## Queued\n' + ''.join(f'- [ ] item-{i} - Accepted {i}\n  First\n  Second\n' for i in range(8)))
    call(recovery, 'migrate-notes', expected=91, extra={'FM_QUEUE_TEST_CRASH_AFTER_WRITES': '2'})
    call(recovery, 'list')
    for i in range(8):
        assert task(recovery, f'item-{i}')['body'] == 'First\nSecond'
    assert not (recovery / 'data/backlog.md.transaction').exists()
    assert json.loads(call(recovery, 'migrate-notes'))['migrated'] == []
    passed('An interrupted multi-task migration recovers all notes through the next normal queue command')

    backup_home = home(parent, 'backup-source')
    for identifier in ('queued', 'running', 'held', 'retained', 'archived', 'empty'):
        call(backup_home, 'add', identifier, identifier, '--body', 'Original scope')
        source = backup_home / 'input.md'
        source.write_text('' if identifier == 'empty' else f'Current {identifier} scope\n雪\n')
        call(backup_home, 'update', identifier, '--body-file', str(source))
    call(backup_home, 'start', 'running')
    call(backup_home, 'hold', 'held', '--kind', 'captain', '--reason', 'Choose scope')
    call(backup_home, 'done', 'archived', '--keep', '0')
    call(backup_home, 'done', 'retained', '--no-prune')
    active = json.loads(call(backup_home, 'list', '--json'))
    archived = json.loads(call(backup_home, 'show', 'archived', '--history', '--json'))
    backup = parent / 'backup'
    call(backup_home, 'migrate', '--backup-dir', str(backup))
    manifest = json.loads((backup / 'manifest.json').read_text())
    print('\nBACKUP MANIFEST:\n' + json.dumps(manifest, indent=2))
    # Manifest source paths are canonical; match by each file's inode identity
    # rather than assuming the host has no /home -> /var/home alias.
    saved_sources = [Path(entry['source']) for entry in manifest]
    for identifier in ('queued', 'running', 'held', 'retained', 'empty'):
        assert any(p.samefile(backup_home / f'data/{identifier}/notes.md') for p in saved_sources)
    assert [entry['backup'] for entry in manifest[:3]] == ['0-backlog.md', '1-done-archive.md', '2-note-archive.md']
    restored = home(parent, 'restored')
    for entry in manifest:
        original_path = Path(entry['source'])
        saved = backup / entry['backup']
        assert saved.read_bytes() == original_path.read_bytes()
        assert hashlib.sha256(saved.read_bytes()).hexdigest() == entry['sha256']
        # All records in this default-layout manifest belong under data/.
        relative = original_path.parts[original_path.parts.index('backup-source') + 1:]
        target = restored.joinpath(*relative)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(saved, target)
    shutil.rmtree(backup_home)
    assert json.loads(call(restored, 'list', '--json')) == active
    # History locations identify the selected queue root; compare record content
    # independently of that intentionally changed location.
    restored_history = json.loads(call(restored, 'show', 'archived', '--history', '--json'))
    for record in archived['records']:
        record.pop('location')
    for record in restored_history['records']:
        record.pop('location')
    assert restored_history == archived
    call(restored, 'update', 'queued', '--body', 'Continued after restore')
    assert task(restored, 'queued')['body'] == 'Continued after restore'
    passed('Backup captures every referenced active notes file with hashes, restores without the source home, and supports continued edits')

    safety = home(parent, 'safety')
    sentinel = parent / 'sentinel'
    sentinel.mkdir()
    (sentinel / 'keep.md').write_text('Untouched')
    (safety / 'data/unsafe').symlink_to(sentinel, target_is_directory=True)
    assert 'symlink' in call(safety, 'add', 'unsafe', 'Unsafe task', '--body', 'Scope', expected=1)
    assert (sentinel / 'keep.md').read_text() == 'Untouched'
    assert sorted(p.name for p in sentinel.iterdir()) == ['keep.md']
    call(safety, 'add', 'missing', 'Missing notes guard', '--body', 'Scope')
    (safety / 'data/missing/notes.md').unlink()
    before = state(safety)
    assert 'missing task notes' in call(safety, 'show', 'missing', expected=1)
    assert state(safety) == before
    passed('Symlinked task folders and missing note targets fail clearly without changing unrelated files')

(EVIDENCE / 'live-scenario-results.json').write_text(json.dumps(results, indent=2) + '\n')
print('\nAll disposable homes removed. Scenario results:', json.dumps(results), flush=True)
