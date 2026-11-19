import os,subprocess,pathlib,json,time,hashlib
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7RND5YJKT5A6WVSCF8K461C'); pilot=root/'.pilot-validation'; lab=pilot/'home'; state=lab/'state'; ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7RND5YJKT5A6WVSCF8K461C'); remote='/Users/runkai/firstmate-remote-pilot/tasks/pilot'
env=dict(os.environ,FM_HOME=str(lab))
for k in list(env):
 if k.startswith('FM_') and k.endswith('_OVERRIDE'): del env[k]
def note(s):
 print(s,flush=True)
 with (ev/'live-pilot.log').open('a') as f: f.write(s+'\n')
def run(args,extra=None,check=True,timeout=90):
 e=dict(env); e.update(extra or {}); r=subprocess.run(args,cwd=root,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
 note('$ '+' '.join(args)+'\n'+r.stdout+'exit='+str(r.returncode))
 if check and r.returncode: raise RuntimeError(args)
 return r
def ssh(script): return run(['ssh','-o','BatchMode=yes','fm-pilot-pegasus',script])
def sync(extra=None): return run(['bin/fm-remote-task.sh','sync','fm-pilot'],extra)
def fields(name): return dict(line.split('=',1) for line in (state/name).read_text().splitlines() if '=' in line)
def focus():
 w=json.loads(run(['herdr','--machine','fm-pilot','workspace','list']).stdout)['result']['workspaces']; ws=[x['workspace_id'] for x in w if x.get('focused')]; assert ws==json.loads((pilot/'focus-ws.json').read_text())
 t=json.loads(run(['herdr','--machine','fm-pilot','tab','list','--workspace',ws[0]]).stdout)['result']['tabs']; assert [x['tab_id'] for x in t if x.get('focused')]==json.loads((pilot/'focus-tab.json').read_text()); note('FOCUS VERIFIED: original captain workspace and tab unchanged')
