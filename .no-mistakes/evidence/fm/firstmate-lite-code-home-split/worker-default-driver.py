import os,pathlib,json,subprocess,shlex,hashlib
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M74F8VZ5BTPW2N5AC6ZD1V83'); E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M74F8VZ5BTPW2N5AC6ZD1V83'); W=R/'.lv'; H=W/'second home'
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','TASKS_AXI_')): env.pop(k,None)
env.update(HOME=str(W/'user'),XDG_DATA_HOME=str(W/'share'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='url.file://'+str(W/'origin')+'.insteadOf',GIT_CONFIG_VALUE_0='https://github.com/runkaiz/firstmate-lite.git')
log=[]
def run(args,cwd=R,extra=None):
    p=subprocess.run(['rtk',*map(str,args)],cwd=cwd,env={**env,**(extra or {})},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    log.append('$ '+shlex.join(map(str,args))+'\n'+p.stdout+'[exit '+str(p.returncode)+']'); assert p.returncode==0; return p

def state(): return {str(p.relative_to(H/'state')):hashlib.sha256(p.read_bytes()).hexdigest() for p in (H/'state').rglob('*') if p.is_file()}
before=state()
p=run([H/'bin/fm-start.sh','bin/fm-sessionstart-run.sh','--source','startup'],cwd=H,extra={'FM_TASK_ID':'disposable-worker'})
assert p.stdout=='' and before==state()
log.append('OBSERVED: A worker marker suppresses primary startup in a linked home; no digest and no private state writes. Tested in the other home to exclude asynchronous cleanup from native primary startup.')
# Default installer paths are contained under this disposable HOME.
env.pop('XDG_DATA_HOME',None)
p=run([R/'bin/fm-install.sh'])
default=W/'user/firstmate'; default_code=W/'user/.local/share/firstmate'
assert os.path.samefile(default/'bin',default_code/'bin') and not (default/'.git').exists()
run([default/'bin/fm-start.sh','python3','-c','import os; print("default home cwd:",os.getcwd()); print("code:",os.environ["FM_ROOT_OVERRIDE"])'],cwd=default)
log.append('OBSERVED: No-argument installer uses $HOME/.local/share/firstmate and $HOME/firstmate; the resulting default home launches correctly.')
(E/'worker-and-default-transcript.log').write_text('\n\n'.join(log)+'\n')
for result in json.loads((E/'native-results.json').read_text()):
    assert all(result[k] for k in ['linked_instructions','linked_skill','startup_digest','completion_record']),result
(E/'native-observations.log').write_text('\n'.join(x['cli']+': emitted request contains linked instructions, unique installed skill NATIVE_SPLIT_SKILL_7B3A, private-home SESSION START; native session completion recorded.' for x in json.loads((E/'native-results.json').read_text()))+'\nLocal probe returns HTTP 400 deliberately after capture; this proves discovery and startup delivery, not model behavior or provider authentication.\n')
