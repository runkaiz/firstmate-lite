from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round2')
exec((E/'live-friction.py').read_text().split("run(['bin/fm-lab-home.sh'")[0].replace("'w',buffering=1", "'a',buffering=1"))
state=json.loads((E/'live-state.json').read_text());env['TMUX']=state['socket']+',0,0'
q=R/'bin/fm-queue.sh'
out=run([q,'add','fix-login','--kind','ship','--title','Fix it'],good=1)
assert '--title is not an add flag' in out and 'example:' in out
out=run([q,'add'],good=1);assert 'usage: add' in out
run([q,'add','fix-login','Fix the login redirect','--kind','ship'])
out=run([q,'show','fix-login','--json']);assert json.loads(out)['task']['title']=='Fix the login redirect'
log.write('VERIFIED: wrong add syntax gives a usable example; corrected command persists the requested title.\n')
# Read-only missing-home checks from the disposable project, as an ordinary CLI caller.
saved=dict(env)
env.pop('FM_HOME',None);env.pop('NO_MISTAKES_GATE',None)
for tool,args in [('fm-control.sh',['absent-task','relaunch','--note','Spaces; $(touch injected)']),('fm-send.sh',['absent-task','Spaces; $(touch injected)'])]:
    out=run([R/'bin'/tool,*args],good=1,cwd=P)
    assert 'FM_HOME is not set' in out and 'next: name the home explicitly' in out
    cmd=next(l.strip() for l in out.splitlines() if l.startswith('  FM_HOME='))
    assert shlex.split(cmd)[2:]==args
    assert not (P/'injected').exists()
env.clear();env.update(saved)
log.write('VERIFIED: control and send retain explicit-home refusal and quote original arguments safely.\n')
# An actual unlanded commit requires --retain-branch after the printed retry.
ID='retry-live';base=run(['git','-C',P,'rev-parse','main']).strip()
run(['bash','-c','. bin/fm-git-worktree-lib.sh; fm_git_worktree_allocate "$1/state" "$2" "$1" "$3" "$4" "$5" refs/heads/main','_',H,ID,P,C,base])
W=C/ID/'worktree';run(['git','-C',W,'switch','-c','lab-retained'])
(W/'README.md').write_text('unique committed work\n')
run(['git','-C',W,'add','README.md']);run(['git','-C',W,'-c','user.name=Lab','-c','user.email=lab@example.invalid','commit','-m','retained work'])
head=run(['git','-C',W,'rev-parse','HEAD']).strip()
record=dict(l.split('=',1) for l in (H/'state'/f'{ID}.git-worktree').read_text().splitlines() if '=' in l)
meta=H/'state'/f'{ID}.meta'
meta.write_text(f'window=fm-lab-friction:fm-{ID}\nendpoint_task_id={ID}\nbackend=tmux\nworktree={record["path"]}\nproject={record["project"]}\nkind=ship\nmode=local-only\nspawn_gen=s1792922400.123.789\nallocator=git\nbranch=lab-retained\n')
(W/'build').mkdir();(W/'build/out').write_text('generated output')
out=run([R/'bin/fm-teardown.sh',ID,'--retain-branch','--legacy-record'],good=1)
cmd=next(l.strip() for l in out.splitlines() if l.startswith('  FM_HOME='))
assert '--retain-branch --legacy-record' in cmd
run(['bash','-c',cmd])
assert not W.exists() and not meta.exists()
assert run(['git','-C',P,'rev-parse','refs/heads/lab-retained']).strip()==head
assert run(['git','-C',P,'rev-parse','refs/firstmate/retained-work/'+ID]).strip()==head
assert (H/'data'/ID/'preserved-artifacts/files/build/out').read_text()=='generated output'
log.write('VERIFIED: printed retry executes successfully, preserves output, and retains the unlanded commit on its branch and retained-work ref.\n')
print('Queue guidance, missing-home refusal and escaping, and execution of retain-branch retry passed.')
