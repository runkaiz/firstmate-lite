import os, subprocess, pathlib, json, shutil
root=pathlib.Path.cwd(); work=root/'.test-native-gh'; lab=work/'lab'
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M61VX1Y6D34QBB3QP6V66952')
log=open(ev/'live-cli.log','w')
env=os.environ.copy()
for k in list(env):
 if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','TMUX','TMUX_PANE'): env.pop(k,None)
env.update(FM_HOME=str(lab),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_TERMINAL_PROMPT='0',GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
def run(args,cwd=root,check=True,extra=None):
 e=env.copy(); e.update(extra or {})
 p=subprocess.run(args,cwd=cwd,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.write('$ '+' '.join(map(str,args))+'\n'+p.stdout+'\nexit='+str(p.returncode)+'\n'); log.flush()
 if check and p.returncode: raise RuntimeError(p.stdout)
 return p
run(['bash','bin/fm-lab-home.sh','create',str(lab)])
for mode in ('no-mistakes','direct-PR','local-only','scout'):
 args=['bash','bin/fm-brief.sh','lab-'+mode.lower(),'disposable-project']
 args+=['--scout'] if mode=='scout' else ['--mode',mode]
 run(args)
 shutil.copyfile(lab/'data'/('lab-'+mode.lower())/'brief.md',ev/('generated-'+mode+'.md'))
print('Generated all four real brief variants')
# Fresh repository and real forge data; no mutation of any upstream reference.
project=lab/'projects'/'proof'; project.mkdir()
run(['git','init','-q','-b','main'],project)
run(['git','remote','add','origin','https://github.com/runkaiz/firstmate-lite.git'],project)
run(['git','fetch','--quiet','--depth=2','origin','refs/pull/5/head:refs/heads/proof-base'],project)
run(['git','checkout','-q','proof-base'],project)
run(['git','branch','main','HEAD'],project)
run(['git','checkout','-q','main'],project)
# No global Treehouse configuration; its pool and home are disposable.
private=work/'tool-home'; private.mkdir(exist_ok=True)
env.update(HOME=str(private),GH_CONFIG_DIR=os.environ.get('GH_CONFIG_DIR',str(pathlib.Path.home()/'.config/gh')),TREEHOUSE_ROOT=str(work/'pool'),TMUX=str(work/'no-server')+',0,0')
slot=run(['treehouse','get','--lease','--no-fetch','--base','main','-b','fm/firstmate-native-archive-compatibility'],project).stdout.strip().splitlines()[-1]
(work/'slot').write_text(slot)
print('Slot:',slot)
meta=lab/'state'/'lab-cleanup.meta'
meta.write_text('window=lab-only:fm-lab-cleanup\nendpoint_task_id=lab-cleanup\nworktree='+slot+'\nproject='+str(project)+'\nkind=ship\nmode=no-mistakes\nspawn_gen=lab-cleanup-generation\n')
(lab/'config'/'backlog-backend').write_text('manual\n')
p=run(['bash','bin/fm-teardown.sh','lab-cleanup'],check=False)
print(p.returncode,p.stdout[-3500:])
print('Metadata exists:',meta.exists())
