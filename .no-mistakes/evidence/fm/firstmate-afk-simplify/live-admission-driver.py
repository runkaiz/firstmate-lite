import os,pathlib,subprocess,shutil,json
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E481GYSFK0PPVV3M8EZBS6')
EVID=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E481GYSFK0PPVV3M8EZBS6')
HOME=ROOT/'.test-phase/admission-home'
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'):
        env.pop(key)
env.update(FM_HOME=str(HOME),TMPDIR=str(ROOT/'.test-phase/tmp'))
log=[]
def run(name,*args,extra=None):
    e=env.copy(); e.update(extra or {})
    p=subprocess.run([str(ROOT/'bin'/name),*args],cwd=ROOT,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    log.extend(['$ '+name+' '+' '.join(args),p.stdout,'exit='+str(p.returncode)+'\n'])
    return p
try:
    p=run('fm-lab-home.sh','create',str(HOME)); assert p.returncode==0,p.stdout
    p=run('fm-afk-contract.sh','enter','--words','Continue approved queued work.'); assert p.returncode==0,p.stdout
    record=HOME/'state/.afk-contract'
    # Recreate a live pre-upgrade record whose retired budget is already full.
    text=record.read_text().replace('words: |-','expected_return: 2000-01-01T00:00:00Z\nreach_channels: none\nreach_announced: No phone channel is configured.\nspend_max_concurrent_workers: 1\nwords: |-')
    record.write_text(text)
    for task in ('existing-a','existing-b'):
        (HOME/f'state/{task}.meta').write_text('kind=ship\nwindow=fm-'+task+'\n')
    log.extend(['Persisted pre-upgrade record:',text,'Retained workers: existing-a, existing-b (2); retired cap: 1.'])
    # Quiet -> away relocation remains enforced, before ordinary project validation.
    p=run('fm-spawn.sh','probe',str(HOME/'missing-project'),'--mode','local-only','--yolo','off','--backend','tmux','--harness','claude')
    assert p.returncode!=0
    log.append('Fresh MAIN spawn response is above; now probe the branch with no queued task.')
    p=run('fm-spawn.sh','probe',str(HOME/'missing-project'),'--mode','local-only','--yolo','off','--backend','tmux','--harness','claude',extra={'FM_SUPERVISION_ACTOR':'branch'})
    assert p.returncode!=0 and 'queued unblocked work' in p.stdout,p.stdout
    assert 'caps concurrent workers' not in p.stdout
    # A queue entry is created by the real native queue, never by a queue stub.
    p=run('fm-tasks-axi.sh','add','probe','Budget removal dispatch probe')
    assert p.returncode==0,p.stdout
    p=run('fm-spawn.sh','probe',str(HOME/'missing-project'),'--mode','local-only','--yolo','off','--backend','tmux','--harness','claude',extra={'FM_SUPERVISION_ACTOR':'branch'})
    assert p.returncode!=0,p.stdout
    assert 'caps concurrent workers' not in p.stdout
    assert 'project' in p.stdout and 'queued unblocked work' not in p.stdout,p.stdout
    project=HOME/'projects/probe-project'
    project.mkdir(parents=True)
    p=subprocess.run(['git','init','-q','-b','main',str(project)],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
    assert p.returncode==0,p.stdout
    for task in ('existing-a','existing-b'):
        with (HOME/f'state/{task}.meta').open('a') as f:
            f.write('project='+str(project)+'\n')
    capacity=HOME/'config/project-capacity'
    capacity.write_text('probe-project 1\n')
    p=run('fm-spawn.sh','probe',str(project),'--mode','local-only','--yolo','off','--backend','tmux','--harness','claude',extra={'FM_SUPERVISION_ACTOR':'branch'})
    assert p.returncode==75 and '2 already hold a place' in p.stdout,p.stdout
    capacity.unlink()
    p=run('fm-spawn.sh','probe',str(project),'--mode','local-only','--yolo','off','--backend','tmux','--harness','claude',extra={'FM_SUPERVISION_ACTOR':'branch'})
    assert p.returncode==1 and 'no brief' in p.stdout,p.stdout
    p=run('fm-tasks-axi.sh','show','probe','--full')
    assert p.returncode==0 and 'queued' in p.stdout.lower(),p.stdout
    assert not (HOME/'state/probe.meta').exists()
    log.append('Observed: the retired full budget did not block dispatch; queued-work permission and missing-project validation remained active. No worker was launched.')
finally:
    (EVID/'live-admission-cli.log').write_text('\n'.join(log))
    shutil.rmtree(HOME,ignore_errors=True)
print('Admission probes complete; see live-admission-cli.log')
