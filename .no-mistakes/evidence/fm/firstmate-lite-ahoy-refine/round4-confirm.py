import shutil
from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
exec((E/'round4-chat-driver.py').read_text().split("q('add','ahoy-worker'")[0])
assert not L.exists()
(L.parent/'.ahoy-validation-tmp').mkdir()
run('bash','bin/fm-lab-home.sh','create',str(L))
(L/'tmux').mkdir()
try:
    (L/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (L/'data/secondmates.md').write_text('')
    (L/'config/supervision-host-off').touch()
    run('bash','bin/fm-bearings-snapshot.sh','--json','--record-look')
    (L/'data/backlog.md').rename(L/'data/backlog.saved.md')
    for label in ['missing-confirm','missing-confirm-repeat','missing-confirm-third']:
        reply,snap=chat(label)
        assert snap['contributions']['unreadable_records']==1
        assert not snap['gates'] and not snap['decisions_open'] and not snap['in_flight'] and not snap['landed']
        print(reply,flush=True)
    (L/'data/backlog.saved.md').rename(L/'data/backlog.md')
    reply,snap=chat('quiet-restored')
    assert snap['contributions']['unreadable_records']==0
    print(reply,flush=True)
finally:
    run('tmux','-L','fm-lab','kill-server',check=False)
    shutil.rmtree(L)
    shutil.rmtree(L.parent/'.ahoy-validation-tmp')
    print('Confirmation lab and private server removed.',flush=True)
