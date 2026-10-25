import os,pathlib,subprocess,shutil
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M5TETBKV45J8FE1S494BH8ZK')
lab=root/'.test-validation/custody'
evidence=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M5TETBKV45J8FE1S494BH8ZK')
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'): env.pop(k,None)
env.update(FM_HOME=str(lab),PATH='/usr/bin:/bin',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Validation',GIT_AUTHOR_EMAIL='test@example.invalid',GIT_COMMITTER_NAME='Validation',GIT_COMMITTER_EMAIL='test@example.invalid')
log=open(evidence/'custody-cli.log','w')
def run(*args,expected=0):
    p=subprocess.run(args,env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=20)
    log.write('$ '+' '.join(args)+'\n'+p.stdout+f'EXIT={p.returncode}\n');log.flush()
    assert p.returncode==expected,(args,p.stdout)
    return p.stdout.strip()
try:
    run('bin/fm-lab-home.sh','create',str(lab))
    remote=lab/'remote.git'; repo=lab/'projects/demo'; wt=lab/'worker'
    run('git','init','--bare','-q',str(remote))
    run('git','init','-q','-b','main',str(repo))
    run('git','-C',str(repo),'commit','-q','--allow-empty','-m','Initial disposable fixture')
    run('git','-C',str(repo),'remote','add','origin',str(remote))
    run('git','-C',str(repo),'push','-q','-u','origin','main')
    run('git','-C',str(repo),'worktree','add','-q','-b','fix',str(wt))
    run('git','-C',str(wt),'commit','-q','--allow-empty','-m','Named head only in worker')
    sha=run('git','-C',str(wt),'rev-parse','HEAD')
    meta=lab/'state/demo.meta'
    meta.write_text(f'kind=ship\nmode=no-mistakes\nworktree={wt}\nproject={repo}\n')
    original=meta.read_bytes()
    url='https://github.com/example/disposable-validation/pull/1'
    out=run('bin/fm-pr-check.sh','demo',url,expected=1)
    assert sha in out and 'unreachable outside the worker copy' in out
    assert original==meta.read_bytes() and not (lab/'state/demo.check.sh').exists()
    run('git','-C',str(wt),'push','-q','-u','origin','fix')
    out=run('bin/fm-pr-check.sh','demo',url)
    assert 'armed: state/demo.check.sh' in out
    assert 'pr='+url in meta.read_text()
    assert (lab/'state/demo.check.sh').exists()
    log.write('Only disposable local Git was pushed; no forge CLI was on PATH. Refused unpushed named head without recording PR; accepted after real local-remote push.\n')
finally:
    shutil.rmtree(lab,ignore_errors=True)
    log.write('Disposable Git repositories and lab removed.\n');log.close()
