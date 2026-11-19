import os, subprocess, pathlib, json
root=pathlib.Path.cwd(); pilot=root/'.pilot-validation'; lab=pilot/'home'; repo=pilot/'throwaway'; ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7RND5YJKT5A6WVSCF8K461C')
env=dict(os.environ, FM_HOME=str(lab))
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE'): del env[k]
def run(args, **kw):
 r=subprocess.run(args,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,**kw)
 with (ev/'live-pilot.log').open('a') as f: f.write('$ '+' '.join(args)+'\n'+r.stdout+'\nexit='+str(r.returncode)+'\n')
 print(r.stdout,flush=True)
 if r.returncode: raise RuntimeError(args)
 return r.stdout
run(['bin/fm-lab-home.sh','create',str(lab)])
(lab/'config/worktree-allocator').write_text('git\n'); (lab/'config/git-worktree-root').write_text(str(pilot/'copies')+'\n'); (lab/'config/backlog-backend').write_text('manual\n')
(lab/'config/remote-machines').write_text('966df3cddb5e527a693a675d66d27109 fm-pilot ~/firstmate-remote-pilot\n')
repo.mkdir(); run(['git','init','-b','main',str(repo)]); run(['git','-C',str(repo),'config','user.name','Pilot']); run(['git','-C',str(repo),'config','user.email','pilot@example.invalid'])
(repo/'README.md').write_text('Disposable remote placement pilot.\n'); run(['git','-C',str(repo),'add','README.md']); run(['git','-C',str(repo),'commit','-m','Initial pilot'])
run(['bin/fm-brief.sh','pilot',str(repo),'--mode','local-only','--machine','fm-pilot','--herdr-lab'])
b=lab/'data/pilot/brief.md'; text=b.read_text().replace('{TASK}', 'In this disposable pilot repository, create hello.txt containing remote pilot, commit it, append a working status, then append a paused [key=pilot-ready] status asking to continue. Stay available for steering. Do not push or create a pull request.').replace('{FIRSTMATE_SPEC}', 'Use git -c user.name=Pilot -c user.email=pilot@example.invalid commit if identity is needed. Write status to the remote channel specified above. Do not use any Herdr lifecycle commands. Do not touch anything outside this repository and its channel. Once hello.txt is committed, wait for further instructions.')
b.write_text(text)
# Record only focus identities, never the captain's page content.
r=run(['herdr','--machine','fm-pilot','workspace','list']); ws=json.loads(r)['result']['workspaces']; focus=[w['workspace_id'] for w in ws if w.get('focused')]; (pilot/'focus-ws.json').write_text(json.dumps(focus))
if len(focus)!=1: raise RuntimeError('unreadable focus')
r=run(['herdr','--machine','fm-pilot','tab','list','--workspace',focus[0]]); tabs=json.loads(r)['result']['tabs']; (pilot/'focus-tab.json').write_text(json.dumps([t['tab_id'] for t in tabs if t.get('focused')]))
run(['bin/fm-spawn.sh','pilot',str(repo),'--machine','fm-pilot','--mode','local-only','--yolo','off'])
run(['bin/fm-remote-task.sh','sync','fm-pilot']); run(['bin/fm-peek.sh','pilot','45'])
