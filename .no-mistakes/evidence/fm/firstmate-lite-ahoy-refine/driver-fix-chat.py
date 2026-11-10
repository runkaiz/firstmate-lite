import json, os, pathlib, subprocess, sys, time
ROOT = pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
LAB = ROOT/'.l'
E = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
label = sys.argv[1]
env = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'NO_MISTAKES_', 'GIT_', 'TMUX'))}
env.update(FM_HOME=str(LAB), FM_BACKEND='tmux', TMUX_TMPDIR=str(LAB/'tmux'), TMPDIR=str(ROOT/'.ahoy-validation-tmp'), GIT_CEILING_DIRECTORIES=str(ROOT))
def run(*args):
    return subprocess.run(args, cwd=ROOT, env=env, text=True, capture_output=True, check=True).stdout
def q(*args):
    return run('python3', 'bin/fm-queue.py', *args, '--file', str(LAB/'data/backlog.md'))
for d in ['data', 'state', 'projects', 'config', 'tmux']:
    (LAB/d).mkdir(parents=True, exist_ok=True)
(ROOT/'.ahoy-validation-tmp').mkdir(exist_ok=True)
if not (LAB/'config/supervision-host-off').exists():
    (LAB/'config/supervision-host-off').touch()
    (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    (LAB/'data/secondmates.md').write_text('')
    run('tmux', '-S', str(LAB/'t'), 'new-session', '-d', '-s', 'primary', '-x', '120', '-y', '40', '-c', str(ROOT), 'sleep 3600')
    for ident,title,kind,args in [
        ('merged', 'Fix the authentication redirect', 'ship', ['--pr','https://github.com/example/lab/pull/12']),
        ('local', 'Simplify the local launcher', 'ship', ['--note','local main']),
        ('scouted', 'Investigate portability', 'scout', ['--report','data/scouted/report.md'])]:
        q('add',ident,title,'--kind',kind)
        if ident=='scouted':
            (LAB/'data/scouted').mkdir()
            (LAB/'data/scouted/report.md').write_text('# Portability investigation\nDisposable completed report.\n')
        q('done',ident,*args)
    q('add','next','Improve the integration workflow with a complete title longer than sixty characters','--kind','ship')
    for args in [
        ['conditional','--title','Revisit the integration approach','--reason','Choose integration','--when','the upstream API stabilizes'],
        ['dated','--title','Review the release','--reason','Choose release','--until','2099-01-01']]:
        run('bash','bin/fm-captain-hold.sh','hold',*args)
    q('add','ahoy-worker','Produce the current fleet catch-up','--kind','scout')
    q('start','ahoy-worker')
    (LAB/'projects/ahoy-worker').mkdir()
    (LAB/'state/ahoy-worker.meta').write_text(f'window=primary:0\nbackend=tmux\nworktree={LAB}/projects/ahoy-worker\nproject=lab\nharness=claude\nkind=scout\nmode=scout\nspawn_gen=s{int(time.time())-900}.1.1\npr=https://github.com/example/lab/pull/99\n')
env['TMUX']=run('tmux','-S',str(LAB/'t'),'display-message','-p','#{socket_path},#{pid},0').strip()
# Reproduce the same implementing-to-done transition for every fresh evaluation.
(LAB/'state/ahoy-worker.status').write_text('working: producing the Ahoy update\n')
run('bash','bin/fm-busy-event.sh','arm',str(LAB/'state'),'ahoy-worker','--state','busy','--source','claude-hook','--event','user-prompt-submit')
run('bash','bin/fm-bearings-snapshot.sh','--json','--record-look')
(LAB/'state/ahoy-worker.status').write_text('done: worker output complete; publication and CI unverified\n')
run('bash','bin/fm-busy-event.sh','arm',str(LAB/'state'),'ahoy-worker','--state','idle','--source','claude-hook','--event','stop')
skill=(ROOT/'.agents/skills/ahoy/SKILL.md').read_text()
context=f"""You are evaluating the Firstmate Ahoy skill in a disposable lab. The complete skill below is the behavior to apply. This is an Ahoy-only invocation: do not run session startup, supervision, dispatch, publication, or any unrelated lifecycle commands. All firstmate state must resolve to FM_HOME={LAB}. Run only bin/fm-bearings-snapshot.sh --json --record-look once, then return the requested glance. Use the existing environment for isolation. Do not read operator state or credentials, modify source, or run any other tool.\n\n{skill}"""
args=['claude','--safe-mode','--print','--no-session-persistence','--setting-sources','','--strict-mcp-config','--tools','Bash,Read','--allowedTools','Bash,Read','--append-system-prompt',context,'--verbose','--output-format','stream-json','Ahoy, give me a catch-up and the current status.']
with (E/f'fix-{label}.stream.jsonl').open('w') as out, (E/f'fix-{label}.stderr').open('w') as err:
    p=subprocess.run(args,env=env,cwd=ROOT,text=True,stdout=out,stderr=err,timeout=240)
assert p.returncode==0, f'Claude failed: {p.returncode}'
rows=[json.loads(line) for line in (E/f'fix-{label}.stream.jsonl').read_text().splitlines()]
result=next(x for x in rows if x.get('type')=='result')
assert result['subtype']=='success' and not result['is_error'] and not result['permission_denials']
reply=result['result']
(E/f'fix-{label}.md').write_text(reply+'\n')
snapshots=[]
commands=[]
for event in rows:
    for block in event.get('message',{}).get('content',[]):
        if block.get('type')=='tool_use': commands.append(block['input'])
        if block.get('type')=='tool_result':
            try: data=json.loads(block['content'])
            except (ValueError,TypeError): continue
            if data.get('schema')=='fm-bearings.v1': snapshots.append(data)
assert len(snapshots)==1
snap=snapshots[0]
(E/f'fix-{label}-snapshot.json').write_text(json.dumps(snap,indent=2)+'\n')
(E/f'fix-{label}-commands.json').write_text(json.dumps(commands,indent=2)+'\n')
assert snap['decisions_open']==[] and snap['contributions']['captain']==[]
assert snap['in_flight'][0]['state']=='done' and snap['in_flight'][0]['stage']=='done'
assert 'unverified' in snap['in_flight'][0]['doing']
assert any(x['surface']=='moving' and x['current']=='done/done' for x in snap['since_last_look']['changes'])
print(reply)
print('\nSnapshot assertions passed; actual completion reply saved.')
