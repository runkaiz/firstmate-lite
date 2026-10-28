"""Read-only independent audit of this run's retained product evidence."""
import hashlib
import json
from pathlib import Path
import subprocess

evidence = Path(__file__).parent
repo = Path('/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M61Q39ZYPMGTHHT7DZ77ZHWN')
result = json.loads((evidence / 'native-retirement-relaunch-result.json').read_text())
head = subprocess.check_output(['git', '-C', str(repo), 'rev-parse', 'HEAD'], text=True).strip()
assert head == result['tested_head_sha'] == '71557b00fe50ec0865cb539a49e12b1e29a64fa7'
records = evidence / 'native-retry-records'
def one(phase, suffix):
    files = list((records / phase).glob('*' + suffix))
    assert len(files) == 1, (phase, suffix, files)
    return files[0]
def fields(path):
    return dict(line.split('=', 1) for line in path.read_text().splitlines())
before = one('before-relaunch', '.git-worktree')
after = one('after-relaunch', '.git-worktree')
interrupted = one('interrupted-retirement', '.git-worktree')
assert before.read_bytes() == after.read_bytes() == interrupted.read_bytes()
digest = hashlib.sha256(before.read_bytes()).hexdigest()
marker = fields(one('interrupted-retirement', '.backlog-close'))
assert marker['native_reservation'] == digest
assert marker['mode'] == 'remove' and marker['cleanup_incomplete'] == '0'
reservation = fields(before)
meta_before = fields(one('before-relaunch', '.meta'))
meta_after = fields(one('after-relaunch', '.meta'))
assert meta_before['allocator'] == meta_after['allocator'] == 'git'
assert meta_before['worktree'] == meta_after['worktree'] == reservation['path']
assert meta_before['spawn_gen'] != meta_after['spawn_gen']
assert marker['spawn_gen'] == meta_after['spawn_gen']
inventory_before = (records / 'before-relaunch/worktrees.txt').read_bytes()
assert inventory_before == (records / 'after-relaunch/worktrees.txt').read_bytes()
final_inventory = (records / 'after-replay/worktrees.txt').read_text()
assert final_inventory.count('worktree ') == 1
assert reservation['project'] in final_inventory
assert reservation['path'] not in final_inventory
assert not list((records / 'interrupted-retirement').glob('*.meta'))
assert sorted(p.name for p in (records / 'after-replay').iterdir()) == ['worktrees.txt']
assert result['exit_code'] == 0 and result['elapsed_seconds_including_cleanup'] <= 300
cleanup = {}
for key in ['home', 'project', 'root', 'path']:
    # Persisted records use the host's equivalent /var/home spelling; only
    # inspect the exact instructed worktree prefix in this independent audit.
    saved = reservation[key]
    prefix = '/var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M61Q39ZYPMGTHHT7DZ77ZHWN/'
    assert saved.startswith(prefix)
    path = repo / saved[len(prefix):]
    assert not path.exists(), str(path)
    cleanup[key] = 'absent'
assert not (repo / '.test-phase').exists()
assert not Path(result['processes']['private_socket']).exists()
assert not subprocess.check_output(['git', '-C', str(repo), 'status', '--porcelain'], text=True).strip()
artifacts = ['native-live.log', 'native-recovery-live.log', 'usage-live.log',
             'focused-tests.log', 'lifecycle-tests.log',
             'native-retirement-relaunch.sh', 'native-retirement-relaunch.log',
             'native-retirement-relaunch-result.json']
hashes = {}
for name in artifacts:
    data = (evidence / name).read_bytes()
    assert data
    hashes[name] = hashlib.sha256(data).hexdigest()
print(json.dumps({
    'head': head,
    'audit': 'pass',
    'execution_policy': 'Retained same-run product executions; no scenario rerun in this audit',
    'reservation_sha256': digest,
    'observations': [
        'Reservation bytes and copy inventory unchanged across relaunch',
        'New spawn generation retains allocator=git and original copy path',
        'Retirement marker binds exact reservation digest and replacement generation',
        'Failure snapshot preserves ownership after task metadata disappears',
        'Replay snapshot contains only the original project worktree',
        'Recorded fixture paths, private socket and transient driver are absent',
        'Current worktree is clean; corrected usage evidence path exists'
    ],
    'cleanup': cleanup,
    'retained_artifact_sha256': hashes
}, indent=2))
