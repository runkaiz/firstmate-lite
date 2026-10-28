import os, subprocess, pathlib, json, shutil
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M61VX1Y6D34QBB3QP6V66952'); work=root/'.test-native-gh'; lab=work/'lab'; project=lab/'projects'/'proof'
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M61VX1Y6D34QBB3QP6V66952')
log=open(ev/'live-adversarial.log','w'); results=[]
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(lab),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_TERMINAL_PROMPT='0',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',HOME=str(work/'tool-home'),GH_CONFIG_DIR=os.environ.get('GH_CONFIG_DIR',str(pathlib.Path.home()/'.config/gh')),TREEHOUSE_ROOT=str(work/'pool'),TMUX=str(work/'no-server')+',0,0')
# This transparent observer records arguments and invokes the actual installed CLI.
observer=work/'observe'; observer.mkdir(exist_ok=True)
gh=shutil.which('gh'); shim=observer/'gh'
shim.write_text('#!/usr/bin/env python3\nimport os,sys,json\nwith open(os.environ["LAB_GH_LOG"],"a") as f: f.write(json.dumps(sys.argv[1:])+"\\n")\nos.execv('+repr(gh)+',["gh"]+sys.argv[1:])\n'.replace('"\\n"','"\n"'))
shim.chmod(0o755)
env.update(PATH=str(observer)+':'+env['PATH'],LAB_GH_LOG=str(ev/'native-gh-invocations.jsonl'))
def run(args,cwd=root,check=True,extra=None):
 e=env.copy();e.update(extra or {})
 p=subprocess.run(args,cwd=cwd,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n');log.flush()
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p
run(['git','fetch','--quiet','--depth=2','origin','refs/pull/6/head:refs/heads/open-proof'],project)
for case,branch,base,extra_commit,token in [
 ('merged-discovery','fm/firstmate-native-archive-compatibility','proof-base',False,None),
 ('open-pr','fm/firstmate-calm-codemode-visibility','open-proof',False,None),
 ('missing-pr','fm/lab-native-gh-no-such-branch-01M61VX1','proof-base',False,None),
 ('auth-error','fm/firstmate-native-archive-compatibility','proof-base',False,'invalid-lab-token'),
 ('stale-head','fm/firstmate-native-archive-compatibility','proof-base',True,None)]:
 print('Driving',case,flush=True)
 # Each scenario owns a different local slot and only local fixture refs.
 if run(['git','show-ref','--verify','--quiet','refs/heads/'+branch],project,False).returncode==0:
  run(['git','branch','-D',branch],project)
 slot=run(['treehouse','get','--lease','--no-fetch','--base',base,'-b',branch],project).stdout.strip().splitlines()[-1]
 if extra_commit:
  pathlib.Path(slot,'lab-unlanded.txt').write_text('must survive refused cleanup\n')
  run(['git','add','lab-unlanded.txt'],slot);run(['git','commit','-qm','disposable unlanded work'],slot)
 task='lab-'+case; meta=lab/'state'/(task+'.meta')
 meta.write_text('window=lab-only:fm-'+task+'\nendpoint_task_id='+task+'\nworktree='+slot+'\nproject='+str(project)+'\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-generation-'+case+'\nbase_branch=lab-nonexistent-default-proof-disabled\n')
 before=run(['git','rev-parse','HEAD'],slot).stdout.strip()
 p=run(['bash','bin/fm-teardown.sh',task],check=False,extra={'GH_TOKEN':token} if token else None)
 passed=(p.returncode==0 and not meta.exists()) if case=='merged-discovery' else (p.returncode==1 and meta.exists() and 'REFUSED' in p.stdout and run(['git','rev-parse','HEAD'],slot).stdout.strip()==before)
 results.append({'case':case,'exit':p.returncode,'passed':passed,'metadata_preserved':meta.exists(),'head_before':before})
 # Release the refused scenario's disposable slot explicitly; no real branch is touched.
 if meta.exists():
  run(['treehouse','return','--force',slot],project);meta.unlink()
 print(case, 'PASS' if passed else 'FAIL',p.stdout[-1600:],flush=True)
(ev/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
assert all(x['passed'] for x in results)
