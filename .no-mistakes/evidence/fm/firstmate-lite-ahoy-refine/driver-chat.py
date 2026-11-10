import os,pathlib,subprocess,shlex,json,sys,time
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
LAB=ROOT/'.l'
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
scenario=sys.argv[1] if len(sys.argv)>1 else 'busy'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','NO_MISTAKES_','GIT_'))}
env.update(FM_HOME=str(LAB),FM_BACKEND='tmux',TMUX_TMPDIR=str(LAB/'tmux'),TMPDIR=str(ROOT/'.ahoy-validation-tmp'),GIT_CEILING_DIRECTORIES=str(ROOT))
skill=(ROOT/'.agents/skills/ahoy/SKILL.md').read_text()
def run(*args):
    p=subprocess.run(args,env=env,cwd=ROOT,text=True,capture_output=True,check=True)
    return p.stdout
if scenario.startswith(('moving','done')):
    id='ahoy-worker'
    if not (LAB/'state'/f'{id}.meta').exists():
        run(str(ROOT/'bin/fm-queue.py'),'add',id,'Produce the current fleet catch-up','--kind','scout','--file',str(LAB/'data/backlog.md'))
        run(str(ROOT/'bin/fm-queue.py'),'start',id,'--file',str(LAB/'data/backlog.md'))
    (LAB/'projects/ahoy-worker').mkdir(exist_ok=True)
    (LAB/'state'/f'{id}.meta').write_text(f'window=primary:0\nbackend=tmux\nworktree={LAB}/projects/ahoy-worker\nproject=lab\nharness=claude\nkind=scout\nmode=scout\nspawn_gen=s{int(time.time())-900}.1.1\npr=https://github.com/example/lab/pull/99\n')
    (LAB/'state'/f'{id}.status').write_text('done: worker output complete; publication and CI unverified\n' if scenario.startswith('done') else 'working: producing the Ahoy update\n')
    run(str(ROOT/'bin/fm-busy-event.sh'),'arm',str(LAB/'state'),id,'--state','idle' if scenario.startswith('done') else 'busy','--source','claude-hook','--event','stop' if scenario.startswith('done') else 'user-prompt-submit')
if scenario=='quiet':
    for p in (LAB/'state').glob('*'):
        if p.is_file() or p.is_symlink(): p.unlink()
    import shutil
    for p in (LAB/'data').iterdir():
        if p.is_dir(): shutil.rmtree(p)
        else: p.unlink()
    (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (LAB/'data/secondmates.md').write_text('')
    import datetime
    now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    (LAB/'data/contribution-history').mkdir()
    records=[]
    for i in range(71):
        records.append(dict(url=f'https://github.com/example/lab/pull/{i+1}',kind='pr',pending=[],seen=[],notified=[],error=None,checked_at=now,verdict=None,
            observation=dict(state='open' if i<3 else 'merged',head='1'*40,draft=i<2,mergeable='mergeable',can_merge=False,review_decision='REVIEW_REQUIRED' if i==2 else '',checks=[],reviews=[],events=[])))
    # A green check lets the third record project as awaiting maintainer review.
    records[2]['observation']['checks']=[dict(name='CI',status='completed',conclusion='success')]
    (LAB/'data/contribution-history/contributions.json').write_text(json.dumps(dict(schema='fm-contributions.v1',task='contribution-history',records=records)))
if scenario=='missing':
    (LAB/'data/backlog.md').rename(LAB/'data/backlog.saved.md')
context=f'''You are evaluating the Firstmate Ahoy skill in a disposable lab. The complete skill below is the behavior to apply. This is an Ahoy-only invocation: do not run session startup, supervision, dispatch, publication, or any unrelated lifecycle commands. All firstmate state must resolve to FM_HOME={LAB}. Run only bin/fm-bearings-snapshot.sh --json --record-look once, then return the requested glance. Use the existing environment for isolation. Do not read operator state or credentials, modify source, or run any other tool.\n\n{skill}'''
args=['claude','--safe-mode','--print','--no-session-persistence','--setting-sources','','--strict-mcp-config','--tools','Bash,Read','--allowedTools','Bash,Read','--append-system-prompt',context,'--verbose','--output-format','stream-json','Ahoy, give me a catch-up and the current status.']
cmd=shlex.join(args)+' > '+shlex.quote(str(E/f'chat-{scenario}.stream.jsonl'))+' 2> '+shlex.quote(str(E/f'chat-{scenario}.stderr'))+'; printf "%s\\n" "$?" > '+shlex.quote(str(LAB/f'chat-{scenario}.exit'))
subprocess.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-c',str(ROOT),'-x','120','-y','40','-e','FM_HOME='+str(LAB),cmd],env=env,check=True)
print('Real Claude Ahoy started on isolated fm-lab socket, 120x40 grid.')
