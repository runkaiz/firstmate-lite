from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT/round3')
exec((E/'browser-start.py').read_text().split("print(run(")[0])
log.close();log=open(E/'ignored-cache.log','w',buffering=1)
ID='ignored-cache';base=run(['git','-C',P,'rev-parse','main']).strip()
run(['bash','-c','. bin/fm-git-worktree-lib.sh; fm_git_worktree_allocate "$1/state" "$2" "$1" "$3" "$4" "$5" refs/heads/main','_',H,ID,P,C,base])
W=C/ID/'worktree'
record=dict(l.split('=',1) for l in (H/'state'/f'{ID}.git-worktree').read_text().splitlines() if '=' in l)
meta=H/'state'/f'{ID}.meta'
meta.write_text(f'window=fm-lab-friction:fm-{ID}\nendpoint_task_id={ID}\nbackend=tmux\nworktree={record["path"]}\nproject={record["project"]}\nkind=ship\nmode=local-only\nspawn_gen=s1792922400.123.999\nallocator=git\nbranch=main\n')
(W/'.cache/jdk').mkdir(parents=True);(W/'.cache/jdk/a').write_text('ignored generated output')
run(['git','-C',W,'check-ignore','.cache/jdk/a'])
out=run([R/'bin/fm-teardown.sh',ID],good=1)
assert '.cache (1 file)' in out and (W/'.cache/jdk/a').exists()
cmd=next(l.strip() for l in out.splitlines() if l.startswith('  FM_HOME='))
run(['bash','-c',cmd])
assert not W.exists() and not meta.exists()
assert (H/'data'/ID/'preserved-artifacts/files/.cache/jdk/a').read_text()=='ignored generated output'
log.write('PASS: ignored generated file summarized and preserved by the printed command.\n')
print('Ignored-cache refusal and retry passed.')
