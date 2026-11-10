import json, os, subprocess, pathlib, hashlib

ROOT = pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
LAB = ROOT / '.l'
EVIDENCE = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'NO_MISTAKES_', 'GIT_'))}
env.update(FM_HOME=str(LAB), FM_BACKEND='tmux', TMUX_TMPDIR=str(LAB/'tmux'), TMPDIR=str(ROOT/'.ahoy-validation-tmp'), GIT_CEILING_DIRECTORIES=str(ROOT))

transcript=[]
def run(args, check=True):
    p=subprocess.run(args,cwd=ROOT,env=env,text=True,capture_output=True,timeout=45)
    transcript.append('$ '+ ' '.join(str(x) for x in args)+'\n'+p.stdout+p.stderr)
    if check and p.returncode: raise RuntimeError(transcript[-1])
    return p
def q(*args): return run([str(ROOT/'bin/fm-queue.py'),*args,'--file',str(LAB/'data/backlog.md')])
def hold(*args,check=True): return run([str(ROOT/'bin/fm-captain-hold.sh'),*args],check)
def snap(name,*args):
    p=run([str(ROOT/'bin/fm-bearings-snapshot.sh'),'--json',*args])
    (EVIDENCE/('round3-'+name)).write_text(p.stdout)
    return json.loads(p.stdout)
def get(rows,id): return next(x for x in rows if x['id']==id)

try:
    (LAB/'state/ahoy-last.json').unlink(missing_ok=True)
    (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (LAB/'data/secondmates.md').write_text('')
    (LAB/'config/supervision-host-off').touch()
    queue_title='Improve the integration workflow with a complete title longer than sixty characters'
    q('add','next',queue_title,'--kind','ship')
    q('add','prerequisite','Wait for prerequisite','--kind','ship')
    q('block','next','--by','prerequisite')
    for id,title,kind,args in [
        ('folded','Folded idea','idea',[]),('closed','Closed without delivery','ship',[]),
        ('merged','Fix the authentication redirect','ship',['--pr','https://github.com/example/lab/pull/12']),
        ('local','Simplify the local launcher','ship',['--note','local main']),
        ('scouted','Investigate portability','scout',['--report','data/scouted/report.md'])]:
        q('add',id,title,'--kind',kind)
        if id=='scouted':
            (LAB/'data/scouted').mkdir(exist_ok=True); (LAB/'data/scouted/report.md').write_text('# Portability investigation\nDeliverable from the disposable lab.\n')
        q('done',id,*args)
    hold('hold','conditional','--title','Revisit the integration approach','--reason','Choose integration','--when','the upstream API stabilizes')
    hold('hold','dated','--title','Review the release','--reason','Choose release','--until','2099-01-01')
    hold('hold','call','--title','Choose a launch route','--reason','Pick a route')
    before=(LAB/'data/backlog.md').read_bytes()
    first=snap('live-first-look.json','--record-look')
    assert first['since_last_look']=={'since':None,'changes':[]}
    assert {x['id'] for x in first['landed']}=={'merged','local','scouted'}
    assert all(x['artifact']!='-' for x in first['landed'])
    assert get(first['gates'],'next')['title']==queue_title
    assert {x['id'] for x in first['decisions_open']}=={'call'}
    detail=snap('live-detail.json','--all-decisions')
    assert all(x['id']!='conditional' for x in detail['decisions_open'])
    assert get(detail['gates'],'conditional')['deferred'] is True
    assert get(detail['decisions_open'],'dated')['deferred'] is True
    assert before==(LAB/'data/backlog.md').read_bytes()
    unchanged=snap('live-unchanged.json','--record-look')
    assert unchanged['since_last_look']['changes']==[]
    (LAB/'answer.txt').write_text('Use the direct route.\n')
    hold('answer','call','--decision-file',str(LAB/'answer.txt'))
    q('done','prerequisite')
    q('unblock','next','--by','prerequisite')
    changed=snap('live-transitions.json','--record-look')
    assert any(x['surface']=='call' and x['current']=='no longer observed' for x in changed['since_last_look']['changes'])
    assert any(x['surface']=='next' and x['title']=='Wait for prerequisite' and x['current']=='no longer observed' for x in changed['since_last_look']['changes'])
    assert any(x['surface']=='next' and json.loads(x['current'])==['-','-'] for x in changed['since_last_look']['changes'] if x['current']!='no longer observed')
    assert not any(x['surface']=='landed' for x in changed['since_last_look']['changes'])
    stable=snap('live-stable.json','--record-look')
    assert stable['since_last_look']['changes']==[]
    checkpoint=LAB/'state/ahoy-last.json'
    saved=checkpoint.read_bytes()
    snap('live-monitor.json')
    assert saved==checkpoint.read_bytes()
    checkpoint.write_text('broken checkpoint\n')
    assert snap('live-corrupt-checkpoint.json','--record-look')['since_last_look']['since'] is None
    protected=LAB/'protected.json'; protected.write_bytes(saved)
    checkpoint.unlink(); checkpoint.symlink_to(protected)
    refusal=run([str(ROOT/'bin/fm-bearings-snapshot.sh'),'--json','--record-look'],check=False)
    assert refusal.returncode!=0 and protected.read_bytes()==saved
    (EVIDENCE/'round3-live-symlink-refusal.txt').write_text(refusal.stderr)
    checkpoint.unlink(); checkpoint.write_bytes(saved)
    before=(LAB/'data/backlog.md').read_bytes()
    refusal=hold('hold','conditional','--reason','Both','--when','API stable','--until','2099-01-01',check=False)
    assert refusal.returncode!=0 and before==(LAB/'data/backlog.md').read_bytes()
    (EVIDENCE/'round3-live-conflicting-hold-refusal.txt').write_text(refusal.stderr)
    # Keep this marked disposable home available for the real harness chat check.
    print('Live queue, delivery, deferred-hold, checkpoint-transition, read-only, corrupt-state and refusal checks passed.')
finally:
    (EVIDENCE/'round3-live-cli-transcript.txt').write_text('\n'.join(transcript))
