import os, subprocess, pathlib, json, shlex, shutil, hashlib, time
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6AHC9AFYM09CJWRZYXBSTTT')
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round2')
L=R/'.lv2'; H=L/'home'; P=L/'project'; C=L/'copies'
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'CHROME_DEVTOOLS_AXI_', 'TMUX', 'GIT_'))}
env.update(HOME=str(L/'user'),TMPDIR=str(L/'tmp'),FM_HOME=str(H),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null')
log=open(E/'live-friction.log','w',buffering=1)
def run(args, good=0, cwd=R, extra=None):
    e=dict(env);e.update(extra or {})
    x=subprocess.run([str(a) for a in args],cwd=cwd,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
    log.write('$ '+shlex.join([str(a) for a in args])+'\n'+x.stdout+'[exit '+str(x.returncode)+']\n')
    if good is not None: assert (x.returncode==0)==(good==0),x.stdout
    return x.stdout
run(['bin/fm-lab-home.sh','create',H])
(H/'config/backlog-backend').write_text('manual\n')
P.mkdir();run(['git','init','-b','main',P])
for f in ['README.md','web/package.json','scripts/run.py','docs/notes.md']:
    p=P/f;p.parent.mkdir(parents=True,exist_ok=True);p.write_text('tracked '+f+'\n')
run(['git','-C',P,'add','.']);run(['git','-C',P,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-m','initial'])
base=run(['git','-C',P,'rev-parse','HEAD']).strip()
sock=L/'s';run(['tmux','-S',sock,'-f','/dev/null','new-session','-d','-s','fm-lab-friction','-c',L,'/bin/bash --noprofile --norc'])
env['TMUX']=str(sock)+',0,0'
ID='friction-live'
run(['bash','-c','. bin/fm-git-worktree-lib.sh; fm_git_worktree_allocate "$1/state" "$2" "$1" "$3" "$4" "$5" refs/heads/main','_',H,ID,P,C,base])
W=C/ID/'worktree'; K=H/'data'/ID/'preserved-artifacts'
meta=H/'state'/f'{ID}.meta'
record=dict(l.split('=',1) for l in (H/'state'/f'{ID}.git-worktree').read_text().splitlines() if '=' in l)
meta.write_text(f'window=fm-lab-friction:fm-{ID}\nendpoint_task_id={ID}\nbackend=tmux\nworktree={record["path"]}\nproject={record["project"]}\nkind=ship\nmode=local-only\nspawn_gen=s1792922400.123.456\nallocator=git\nbranch=main\n')
paths=['.cache/jdk','build','web/out','web/node_modules/pkg','web/.next/cache','scripts/__pycache__']
for f in paths:(W/f).mkdir(parents=True,exist_ok=True)
for i in range(16729):(W/'.cache/jdk'/f'{i}.bin').write_text(f'cache {i}')
for f in ['build/out.bin','web/out/index.html','web/node_modules/pkg/index.js','web/.next/cache/a','scripts/__pycache__/run.pyc','web/next-env.d.ts']:(W/f).write_text('generated '+f)
def td(*args,good=1):return run([R/'bin/fm-teardown.sh',ID,*args],good=good)
def intact():
    assert (W/'.cache/jdk/16728.bin').read_text()=='cache 16728'
    assert meta.exists() and not (K/'files').exists()
out=td(); assert '.cache (16729 files)' in out and len(out.splitlines())<50
assert '16728.bin' not in out; intact()
full=H/'data'/ID/'teardown-leftovers.txt'
assert len(full.read_text().splitlines())==16735
shutil.copy(full,E/'teardown-leftovers.txt')
log.write('VERIFIED: 16,735 files summarized under seven roots; full list retained; no files moved.\n')
for args in [('--retain-branch','--legacy-record'),('--landed-pr','https://github.com/fixture/project/pull/1','--landed-head',base,'--legacy-record')]:
    out=td(*args); cmd=next(l.strip() for l in out.splitlines() if l.startswith('  FM_HOME='))
    assert all(x in shlex.split(cmd) for x in args);intact()
out=td('--retain-branch','--legacy-record','--preserve-untracked','.cache/jdk')
assert 'not named' in out and '--retain-branch --legacy-record' in out;intact()
log.write('VERIFIED: initial and partial retries retain original authority options.\n')
(W/'README.md').write_text('unique work\n')
out=td('--preserve-untracked','.cache','--preserve-untracked','web','--preserve-untracked','build','--preserve-untracked','scripts')
assert (W/'README.md').read_text()=='unique work\n';intact()
run(['git','-C',W,'restore','README.md'])
out=td('--preserve-untracked','docs');assert 'holds no leftovers' in out;intact()
log.write('VERIFIED: tracked edits and tracked-only folders refuse without moving generated files.\n')
(E/'live-state.json').write_text(json.dumps({'home':str(H),'project':str(P),'copy':str(W),'id':ID,'socket':str(sock)}))
print('Cleanup summary, retry options, tracked-work guards passed. Setup retained for browser checks.')
