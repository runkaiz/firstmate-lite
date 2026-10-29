import os
from pathlib import Path
import shutil
import subprocess

root = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M62N2AYVWBQFB4KXEE7WECX5')
work = root / '.test-phase-tmp/replay'
evidence = Path('/home/runkai/.no-mistakes/evidence/01M62N2AYVWBQFB4KXEE7WECX5')
env = os.environ.copy()
for key in list(env):
    if key.startswith(('FM_', 'HERDR_', 'TASKS_AXI_')):
        env.pop(key)
env.update(TMPDIR=str(root / '.test-phase-tmp'), FM_BOOTSTRAP_NETWORK='skip')
logs = []
def run(args, h, check=True):
    local = env.copy()
    local['FM_HOME'] = str(h)
    p = subprocess.run([str(x) for x in args], cwd=root, env=local, text=True,
                       stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    if check and p.returncode:
        raise RuntimeError(f'{args}: exit {p.returncode}\n{p.stdout}')
    return p.stdout
try:
    for held in (False, True):
        h = work / ('held' if held else 'ordinary')
        run([root / 'bin/fm-lab-home.sh', 'create', h], h)
        run([root / 'bin/fm-queue.sh', 'add', 'task-a', 'Disposable interrupted cleanup'], h)
        run([root / 'bin/fm-queue.sh', 'start', 'task-a'], h)
        if held:
            run([root / 'bin/fm-queue.sh', 'hold', 'task-a', '--kind', 'captain', '--reason', 'Keep this decision open'], h)
        meta = h / 'state/task-a.meta'
        meta.write_text('kind=ship\nbackend=herdr\nspawn_gen=lab.123\nendpoint_session=fm-lab-unstarted\nendpoint_pane_id=w1:p1\n')
        writer = '. "$1/bin/fm-tasks-axi-lib.sh"; . "$1/bin/fm-backlog-transition-lib.sh"; fm_backlog_close_marker_write "$2/state" task-a "$2/data" lab.123 "$3"'
        # Omit the optional argument entirely for ordinary close.
        if not held:
            writer = writer.replace(' "$3"', '')
        run(['bash', '-c', writer, '_', root, h, '--retain'], h)
        marker = h / 'state/task-a.backlog-close'
        before = (meta.read_bytes(), marker.read_bytes())
        out = run([root / 'bin/fm-bootstrap.sh'], h)
        logs.append(f'Case: {h.name}\n$ FM_BOOTSTRAP_NETWORK=skip fm-bootstrap.sh\n{out}')
        assert 'Herdr task cleanup is unfinished; rerun guarded teardown for task-a' in out
        assert before == (meta.read_bytes(), marker.read_bytes())
        queue = run([root / 'bin/fm-queue.sh', 'show', 'task-a', '--json'], h)
        logs.append('$ fm-queue.sh show task-a --json\n' + queue)
        import json
        task = json.loads(queue)['task']
        assert task['state'] == 'in_flight'
        if held:
            assert task['held'] and task['hold_kind'] == 'captain'
        logs.append('Observed: endpoint owner and pending close preserved byte-for-byte; unfinished task remains in flight.\n')
    (evidence / 'bootstrap-replay-live.log').write_text('\n'.join(logs).replace(str(work), '<disposable-lab>'))
    print('Real bootstrap replay preserved ordinary and held interrupted-cleanup records.')
finally:
    shutil.rmtree(work, ignore_errors=True)
