from common import *
import shutil
focus()
remote_cleanup=r'''import os,json,pathlib,shutil,tempfile,glob
base=pathlib.Path.home(); root=base/'firstmate-remote-pilot'; prefix=str(root)+'/'
assert not (root/'tasks/pilot').exists() and not (root/'tasks/pilot-retry').exists(), 'product cleanup incomplete'
store=base/'.claude.json'; obj=json.loads(store.read_text()); projects=obj.get('projects',{}); keys=[k for k in projects if k.startswith(prefix)]; ids=set()
for k in keys:
 row=projects[k]
 for field in ('lastSessionId','sessionId'):
  if isinstance(row.get(field),str): ids.add(row[field])
for p in (base/'.claude/projects').glob('*firstmate-remote-pilot*'):
 for f in p.glob('*.jsonl'): ids.add(f.stem)
 shutil.rmtree(p)
for sid in ids:
 p=base/'.claude/session-env'/sid
 if p.exists(): shutil.rmtree(p)
for k in keys: del projects[k]
mode=store.stat().st_mode & 0o777
fd,tmp=tempfile.mkstemp(prefix='.claude.json.fm-pilot-cleanup.',dir=base)
with os.fdopen(fd,'w') as f: json.dump(obj,f,indent=2)
os.chmod(tmp,mode); os.replace(tmp,store)
if root.exists(): shutil.rmtree(root)
assert not root.exists()
assert not [k for k in json.loads(store.read_text()).get('projects',{}) if k.startswith(prefix)]
assert not list((base/'.claude/projects').glob('*firstmate-remote-pilot*'))
assert not any((base/'.claude/session-env'/s).exists() for s in ids)
remaining=glob.glob(os.path.join(os.environ.get('TMPDIR','/tmp'),'fm-ps.*'))
print('REMOTE CLEANUP VERIFIED: pilot repository/task/channel absent; '+str(len(keys))+' pilot trust entries and '+str(len(ids))+' pilot sessions removed; unrelated entries retained')
print('Courier temporary files remaining: '+str(len(remaining)))
assert not remaining
'''
run(['ssh','-o','BatchMode=yes','fm-pilot-pegasus',"python3 - <<'PYREMOTE'\n"+remote_cleanup+"\nPYREMOTE"])
run(['herdr','machine','remove','966df3cddb5e527a693a675d66d27109'])
profiles=json.loads(run(['herdr','machine','list','--json']).stdout); assert not any(x['label']=='fm-pilot' for x in profiles); normal=[x for x in profiles if x['id']=='248d057f7775de814ce72fd4fa4a4370']; assert len(normal)==1 and normal[0]['label']=='pegasus' and normal[0]['target']=='pegasus' and normal[0]['enabled'] and not normal[0]['selected']
cfg=pathlib.Path.home()/'.ssh/config'; assert cfg.read_text()=='Host fm-pilot-pegasus\n  HostName pegasus\n  User runkai\n  HostKeyAlias pegasus\n'; cfg.unlink(); assert not cfg.exists()
run(['ssh','-o','BatchMode=yes','pegasus','true']); status=json.loads(run(['herdr','machine','status','pegasus','--json']).stdout); assert status[0]['status']=='reachable'
w=json.loads(run(['herdr','--machine','pegasus','workspace','list']).stdout)['result']['workspaces']; assert [x['workspace_id'] for x in w if x.get('focused')]==json.loads((pilot/'focus-ws.json').read_text()); assert not any(x['label']=='firstmate' or x['label'].startswith('firstmate.') for x in w)
run(['git','-C',str(pilot/'throwaway'),'log','-2','--oneline'])
note('FINAL CLEANUP VERIFIED: captain pegasus profile unchanged and reachable; ssh pegasus works; pilot alias/profile/workspaces absent; original focus unchanged; local disposable folder will now be removed')
# Retain exact reproducer scripts in evidence before deleting the disposable local repositories and home.
for name in ['setup.py','common.py','race.py','outage.py','boundaries.py','cleanup.py','finish-cleanup.py','resume-remove.py','lost-response.py','finalize.py']:
 shutil.copyfile(pilot/name,ev/('driver-'+name))
shutil.rmtree(pilot); assert not pilot.exists()
with (ev/'live-pilot.log').open('a') as f: f.write('LOCAL CLEANUP VERIFIED: .pilot-validation and both disposable homes/repositories removed\n')
