import os, pathlib, subprocess, time, shutil, json

root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ')
lab=root/'.l'
evidence=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E5G3VE4WRF2AH7TSMB9MDJ')
log=open(evidence/'spawn-live.log','w',buffering=1)
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k in ['TMUX','TASKS_AXI_FILE','TASKS_AXI_BACKEND','HERDR_SESSION','HERDR_PANE_ID','HERDR_WORKSPACE_ID','HERDR_TAB_ID'])}
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'t'),XDG_RUNTIME_DIR=str(lab/'run'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_SYSTEM='/dev/null')
def call(args,allow=False,timeout=30):
    print('$ '+repr(args),file=log)
    for attempt in range(20):
        r=subprocess.run(args,env=env,cwd=root,text=True,capture_output=True,timeout=timeout)
        if 'code: LOCKED' not in r.stdout+r.stderr: break
        print('Transient tasks-axi contention; retry '+str(attempt+1),file=log)
        time.sleep(.25)
    print('exit='+str(r.returncode)+'\n'+r.stdout+r.stderr,file=log)
    if not allow and r.returncode: raise RuntimeError(r.stdout+r.stderr)
    return r
tmux=['tmux','-L','fm-lab']
try:
    call(['bash',str(root/'bin/fm-lab-home.sh'),'create',str(lab)])
    (lab/'t').mkdir(); (lab/'run').mkdir()
    call(tmux+['-f','/dev/null','new-session','-d','-s','firstmate','-x','120','-y','40','-c',str(root),'bash --noprofile --norc'])
    socket=str(lab/'t'/('tmux-'+str(os.getuid()))/'fm-lab')
    env['TMUX']=socket+',0,0'
    (lab/'config/worktree-allocator').write_text('git\n')
    (lab/'config/git-worktree-root').write_text(str(root/'.w')+'\n')
    (lab/'config/resource-locks').write_text('suite 2 22:00-09:00=1 full suites\ngpu 1 GPU commands\n')
    (lab/'config/project-capacity').write_text('project 1\n')
    (lab/'.tasks.toml').write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n')
    (lab/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    project=lab/'project'; project.mkdir()
    call(['git','-C',str(project),'init','-q','-b','main'])
    (project/'README.md').write_text('# Disposable dispatch validation project\n')
    call(['git','-C',str(project),'add','README.md'])
    call(['git','-C',str(project),'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','-qm','initial'])
    worker=lab/'worker.sh'
    worker.write_text('#!/usr/bin/env bash\nprintf "worker=%s pid=%s cwd=%s\\n" "$FM_TASK_ID" "$$" "$PWD" | tee "$FM_HOME/$FM_TASK_ID.started"\nwhile [ ! -e "$FM_HOME/release" ]; do sleep .1; done\n')
    # The actual Bash program is the public raw-command interface's workload;
    # it is not impersonating any vendor harness or backend.
    for i,capacity in [(1,'project 1\n'),(2,'project 1\n'),(3,'project two\nproject 1\nproject 1\n')]:
        task='lab-'+str(i)
        (lab/'config/project-capacity').write_text(capacity)
        call(['bash',str(root/'bin/fm-queue.sh'),'add',task,'Disposable dispatch probe '+str(i),'--kind','ship'])
        call(['bash',str(root/'bin/fm-brief.sh'),task,'project','--mode','local-only'])
        brief=lab/'data'/task/'brief.md'
        text=brief.read_text().replace('{TASK}','Validate this disposable launch only.').replace('{FIRSTMATE_SPEC}','Run only the provided Bash workload; do not publish or invoke any pipeline.')
        brief.write_text(text)
        call(['bash',str(root/'bin/fm-spawn.sh'),task,str(project),'bash '+str(worker),'--mode','local-only','--yolo','off','--backend','tmux'],timeout=90)
        deadline=time.monotonic()+10
        while not (lab/(task+'.started')).exists() and time.monotonic()<deadline: time.sleep(.1)
        assert (lab/(task+'.started')).exists(),call(tmux+['capture-pane','-p','-t','firstmate:fm-'+task]).stdout
        print('OBSERVED '+(lab/(task+'.started')).read_text(),file=log)
        assert (lab/'config/project-capacity').read_text()==capacity
        state=call(['bash',str(root/'bin/fm-queue.sh'),'show',task]).stdout
        assert 'in_flight' in state
        call(tmux+['capture-pane','-p','-t','firstmate:fm-'+task])
    windows=call(tmux+['list-windows','-t','firstmate','-F','#{window_name} #{pane_pid} #{pane_current_path}']).stdout
    assert all('fm-lab-'+str(i) in windows for i in [1,2,3])
    print('OBSERVED three simultaneous real tmux Bash jobs in distinct native worktrees despite retired project limit=1; malformed retired declaration also admits third job, remains byte-for-byte unchanged, and all backlog items became in_flight.',file=log)
    task='light-scout'
    (lab/'config/project-capacity').unlink()
    (lab/'config/project-capacity').mkdir()
    call(['bash',str(root/'bin/fm-queue.sh'),'add',task,'Light design scout with busy ships','--kind','scout'])
    call(['bash',str(root/'bin/fm-brief.sh'),task,'project','--scout'])
    brief=lab/'data'/task/'brief.md'
    brief.write_text(brief.read_text().replace('{TASK}','Validate only the disposable scout launch.').replace('{FIRSTMATE_SPEC}','Use only the supplied Bash workload.'))
    call(['bash',str(root/'bin/fm-spawn.sh'),task,str(project),'bash '+str(worker),'--scout','--backend','tmux'],timeout=90)
    deadline=time.monotonic()+10
    while not (lab/(task+'.started')).exists() and time.monotonic()<deadline: time.sleep(.1)
    assert (lab/(task+'.started')).exists()
    assert 'in_flight' in call(['bash',str(root/'bin/fm-queue.sh'),'show',task]).stdout
    call(tmux+['list-windows','-t','firstmate','-F','#{window_name} #{pane_pid} #{pane_current_path}'])
    print('OBSERVED light scout running alongside three ships; unreadable retired capacity path is still a directory and does not block dispatch.',file=log)
    (evidence/'spawn-backlog.md').write_text((lab/'data/backlog.md').read_text())
    # Same machine declarations override a local child's conflicting declaration.
    child=lab/'child'; (child/'config').mkdir(parents=True)
    (child/'.fm-secondmate-parent').write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(lab)+'\n')
    (child/'config/resource-locks').write_text('unrelated 9 child-local configuration\n')
    env['FM_HOME']=str(child)
    r=call(['bash',str(root/'bin/fm-resource-lock.sh'),'brief'])
    assert '`suite`' in r.stdout and '`gpu`' in r.stdout and 'unrelated' not in r.stdout
    print('OBSERVED child home receives root machine declaration and root --file path.',file=log)
finally:
    call(tmux+['kill-server'],allow=True)
    if lab.exists():
        for d,dirs,files in os.walk(lab): os.chmod(d,0o700)
    shutil.rmtree(lab,ignore_errors=True)
    shutil.rmtree(root/'.w',ignore_errors=True)
    print('CLEANUP: private fm-lab tmux server stopped; disposable home, project and native worktrees removed.',file=log)
    log.close()
