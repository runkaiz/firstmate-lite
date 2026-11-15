import pathlib, subprocess, json, os, shutil
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E4EMMHJV5XTAZSM4MWEZTN')
lab=root/'.live-test/home'
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E4EMMHJV5XTAZSM4MWEZTN')
env=dict(os.environ, FM_HOME=str(lab), TMUX_TMPDIR=(lab/'state/.fm-lab-tmux-dir').read_text().strip())
def cmd(*args):
    p=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
    return {'command':list(args),'exit':p.returncode,'output':p.stdout}
files=['config/house-decisions','config/proactive','data/captain.md','data/projects.md','data/backlog.md','data/approved/brief.md','data/restricted/brief.md','data/approved/validation.txt','data/restricted/validation.txt','state/approved.meta','state/restricted.meta','state/approved.busy-state','state/restricted.busy-state','state/.afk-contract']
for task in ('slot1','slot2','slot3'):
    files.append(f'state/{task}.status')
    files.extend(str(p.relative_to(lab)) for p in (lab/f'state/{task}.inbox').glob('*.msg'))
for task in ('approved','restricted'): files.append(f'state/{task}.status')
snapshot={'files':{f:(lab/f).read_text() for f in files},'commands':[]}
for task in ('approved','restricted'):
    snapshot['commands'].append(cmd(str(root/'bin/fm-crew-state.sh'),task))
snapshot['commands'].extend([
    cmd('git','-C',str(lab/'projects/demo'),'rev-parse','main','fm/approved','fm/restricted'),
    cmd('git','-C',str(lab/'projects/demo'),'reflog','--date=iso','--format=%H %gd %gs'),
    cmd('git','-C',str(lab/'projects/demo'),'merge-base','--is-ancestor','fm/restricted','main')])
(ev/'product-state.json').write_text(json.dumps(snapshot,indent=2)+'\n')
shutil.copy(lab/'state/branch-outcomes.jsonl',ev/'supervision-outcomes.jsonl')
shutil.copy(lab/'state/.supervision-host.log',ev/'supervision-host.log')
rows=[json.loads(l) for l in (ev/'supervision-outcomes.jsonl').read_text().splitlines()]
fail=[r for r in rows if r['task']=='approved' and r['verdict']=='captain']
counter=[r for r in rows if 'I landed the approved fix' in r['summary']]
text='Real supervision-host CLI outcomes\n\n'
text+='Observation-only away words: strange, I did not touch ssh or the desktop this time\n'
for r in fail:text+=f"seq={r['seq']} wake={r['wake']}\n{r['summary']}\n\n"
text+='Counterfactual: the same task after explicit landing words\n'
for r in counter:text+=f"seq={r['seq']}\n{r['summary']}\n\n"
text+='Project HEAD reflog (the only fast-forward occurs after the explicit words):\n'+snapshot['commands'][-2]['output']
(ev/'landing-observation.txt').write_text(text)
print(text)
