import json, os, pathlib, shlex, shutil, subprocess, time
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
L=R/'.l'
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','NO_MISTAKES_','GIT_','TMUX'))}
env.update(FM_HOME=str(L),FM_BACKEND='tmux',TMUX_TMPDIR=str(L/'tmux'),TMPDIR=str(R/'.ahoy-validation-tmp'),GIT_CEILING_DIRECTORIES=str(R))
def run(*args,check=True):
    return subprocess.run(args,cwd=R,env=env,text=True,capture_output=True,check=check).stdout
def q(*args): return run('python3','bin/fm-queue.py',*args,'--file',str(L/'data/backlog.md'))
def state(busy):
    (L/'state/ahoy-worker.status').write_text('working: producing the Ahoy update\n' if busy else 'done: worker output complete; publication and CI unverified\n')
    gen=run('bash','bin/fm-busy-event.sh','arm',str(L/'state'),'ahoy-worker').strip()
    run('bash','bin/fm-busy-event.sh','apply',str(L/'state'),'ahoy-worker','busy' if busy else 'idle','--gen',gen,'--source','claude-hook','--event','user-prompt-submit' if busy else 'stop')
def chat(label,prompt='Ahoy, give me a catch-up and the current status.'):
    context=f'''You are evaluating the Firstmate Ahoy skill in a disposable lab. The complete skill below is the behavior to apply. This is an Ahoy-only invocation: do not run session startup, supervision, dispatch, publication, or any unrelated lifecycle commands. All firstmate state must resolve to FM_HOME={L}. Run only bin/fm-bearings-snapshot.sh --json --record-look once, then return the requested glance. Use the existing environment for isolation. Do not read operator state or credentials, modify source, or run any other tool.\n\n'''+(R/'.agents/skills/ahoy/SKILL.md').read_text()
    args=['claude','--safe-mode','--print','--no-session-persistence','--setting-sources','','--strict-mcp-config','--tools','Bash,Read','--allowedTools','Bash,Read','--append-system-prompt',context,'--verbose','--output-format','stream-json',prompt]
    stream=E/f'round2-chat-{label}.stream.jsonl'
    err=E/f'round2-chat-{label}.stderr'
    endfile=L/'exit'
    endfile.unlink(missing_ok=True)
    cmd=shlex.join(args)+' > '+shlex.quote(str(stream))+' 2> '+shlex.quote(str(err))+'; printf "%s\\n" "$?" > '+shlex.quote(str(endfile))
    run('tmux','-L','fm-lab','new-session','-d','-s','primary','-c',str(R),'-x','120','-y','40','-e','FM_HOME='+str(L),cmd)
    try:
        start=time.monotonic()
        while not endfile.exists():
            if time.monotonic()-start>240: raise TimeoutError(label)
            time.sleep(.25)
        assert endfile.read_text().strip()=='0',err.read_text()
        events=[json.loads(x) for x in stream.read_text().splitlines()]
        result=next(x for x in events if x.get('type')=='result')
        assert result['subtype']=='success' and not result['is_error'] and not result['permission_denials'],result
        reply=result['result']
        (E/f'round2-chat-{label}.md').write_text(reply+'\n')
        snapshots=[]; commands=[]
        for event in events:
            for block in event.get('message',{}).get('content',[]):
                if block.get('type')=='tool_use': commands.append(block['input'])
                if block.get('type')=='tool_result':
                    try: data=json.loads(block['content'])
                    except (ValueError,TypeError): continue
                    if isinstance(data,dict) and data.get('schema')=='fm-bearings.v1': snapshots.append(data)
        assert len(snapshots)==1,commands
        (E/f'round2-chat-{label}-snapshot.json').write_text(json.dumps(snapshots[0],indent=2)+'\n')
        (E/f'round2-chat-{label}-commands.json').write_text(json.dumps(commands,indent=2)+'\n')
        print(f'{label}: real Claude completed; response and snapshot saved.',flush=True)
        return reply,snapshots[0]
    finally:
        run('tmux','-L','fm-lab','kill-server',check=False)
q('add','ahoy-worker','Produce the current fleet catch-up','--kind','scout'); q('start','ahoy-worker')
(L/'projects/ahoy-worker').mkdir()
(L/'state/ahoy-worker.meta').write_text(f'window=primary:0\nbackend=tmux\nworktree={L}/projects/ahoy-worker\nproject=lab\nharness=claude\nkind=scout\nmode=scout\nspawn_gen=s{int(time.time())-900}.1.1\npr=https://github.com/example/lab/pull/99\n')
state(True)
busy,snap=chat('busy')
assert snap['in_flight'][0]['stage']=='implementing' and snap['in_flight'][0]['elapsed_seconds']>=900,snap['in_flight']
state(False)
done,snap=chat('done')
assert snap['decisions_open']==[] and snap['contributions']['captain']==[],snap
assert snap['in_flight'][0]['state']=='done' and snap['in_flight'][0]['stage']=='done',snap['in_flight']
assert 'unverified' in snap['in_flight'][0]['doing']
assert any(x['surface']=='moving' and x['current']=='done/done' for x in snap['since_last_look']['changes'])
repeat,snap=chat('done-repeat')
assert snap['since_last_look']['changes']==[]
(L/'state/ahoy-worker.meta').unlink()
q('done','ahoy-worker')
disappeared,snap=chat('disappeared')
assert any(x['surface']=='moving' and x['current']=='no longer observed' for x in snap['since_last_look']['changes'])
assert all(x['surface']!='landed' for x in snap['since_last_look']['changes'])
for folder in ['state','data']:
    for path in (L/folder).iterdir():
        if path.is_dir(): shutil.rmtree(path)
        else: path.unlink()
(L/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
(L/'data/secondmates.md').write_text('')
quiet,snap=chat('quiet')
assert not snap['in_flight'] and not snap['gates'] and not snap['landed'] and not snap['decisions_open']
(L/'data/backlog.md').rename(L/'data/backlog.saved.md')
missing,snap=chat('missing')
assert any('backlog' in x['surface'] for x in snap['omitted'])
print('All live snapshot assertions passed; chat prose awaits direct review.',flush=True)
