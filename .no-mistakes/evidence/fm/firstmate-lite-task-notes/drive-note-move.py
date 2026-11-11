"""Exercise cross-queue notes relocation through the real shell CLI."""
import json
import os
from pathlib import Path
import shlex
import subprocess
import tempfile

root = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M74QH32GCR2CZ6HW0N75KFEK')
with tempfile.TemporaryDirectory(dir=root / '.test-notes-live') as temporary:
    lab = Path(temporary)
    for name in ('source', 'target'):
        (lab / name / 'data').mkdir(parents=True)
        (lab / name / '.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\n')

    def call(name, *args):
        environment = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'NO_MISTAKES_'))}
        environment.update(FM_HOME=str(lab / name), HOME=str(lab / name))
        command = ['bash', str(root / 'bin/fm-queue.sh'), *args]
        print('\nFM_HOME=' + environment['FM_HOME'] + ' ' + shlex.join(command), flush=True)
        run = subprocess.run(command, cwd=lab, env=environment, text=True, capture_output=True, timeout=30)
        print(run.stdout + run.stderr, end='')
        assert run.returncode == 0, run.returncode
        return run.stdout

    (lab / 'input.md').write_bytes(b'Move accepted scope\r\nIndented detail\r\n')
    call('source', 'add', 'movable', 'Move the notes', '--body-file', './input.md')
    notes = lab / 'source/data/movable/notes.md'
    notes.write_bytes(b'External progress\r\nRetained scope\r\n')
    call('source', 'mv', 'movable', '--to', './target/data/backlog.md')
    assert json.loads(call('source', 'list', '--json'))['tasks'] == []
    moved = json.loads(call('target', 'show', 'movable', '--json'))['task']
    assert moved['body'] == 'External progress\nRetained scope\n'
    assert moved['notes_file'] == 'movable/notes.md'
    target_notes = lab / 'target/data/movable/notes.md'
    assert target_notes.read_bytes() == b'External progress\nRetained scope\n'
    call('target', 'done', 'movable', '--keep', '0')
    call('target', 'reopen', 'movable')
    assert json.loads(call('target', 'show', 'movable', '--json'))['task']['body'] == moved['body']
    print('\nPERSISTED DESTINATION BACKLOG:\n' + (lab / 'target/data/backlog.md').read_text())
    print('PERSISTED DESTINATION NOTES:', repr(target_notes.read_bytes()))
print('PROVEN: Relative-path move carries CRLF notes to the destination; destination completion/reopen retains the content. Disposable homes removed.')
