from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M6AHC9AFYM09CJWRZYXBSTTT')
exec((E/'live-friction.py').read_text().split("run(['bin/fm-lab-home.sh'")[0].replace("'w',buffering=1", "'a',buffering=1"))
state=json.loads((E/'live-state.json').read_text());env['TMUX']=state['socket']+',0,0'
ID='retry-live';W=C/ID/'worktree';meta=H/'state'/f'{ID}.meta'
head=run(['git','-C',W,'rev-parse','HEAD']).strip()
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
