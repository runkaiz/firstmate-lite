import os, pathlib, subprocess, time, shutil, json
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ')
LAB=ROOT/'.l'
assert not LAB.exists(), 'Refusing existing lab'
ENV={k:v for k,v in os.environ.items() if not (k.startswith('FM_') and k.endswith('_OVERRIDE')) and k not in ['FM_GATE_REFUSE_BYPASS','FM_TASK_ID','TMUX','TMUX_PANE','TASKS_AXI_FILE','TASKS_AXI_BACKEND','FM_QUEUE_FILE','FM_QUEUE_BACKEND','FM_QUEUE_TEST_CLI']}
ENV.update(FM_HOME=str(LAB),TMUX_TMPDIR=str(LAB/'tmux'),GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
def run(args, timeout=45, check=True, env=ENV):
    p=subprocess.run(list(map(str,args)),cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
    print('$ '+' '.join(map(str,args))+'\n'+p.stdout+'exit='+str(p.returncode),flush=True)
    if check: assert p.returncode==0
    return p
def tmux(*args, **kw): return run(['tmux','-L','fm-lab',*args],**kw)
try:
    run([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir()
    (LAB/'config/supervision-host-off').touch()
    (LAB/'config/worktree-allocator').write_text('git\n')
    (LAB/'config/git-worktree-root').write_text(str(ROOT/'.validation-tmp/copies')+'\n')
    (LAB/'config/crew-harness').write_text('codex\n')
    (LAB/'data/projects.md').write_text('- project [local-only]\n')
    (LAB/'config/resource-locks').write_text('suite 2 22:00-09:00=1 full test suites\ngpu 1 GPU commands\n')
    (LAB/'data/backlog.md').write_text('# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n')
    project=LAB/'projects/project'
    run(['git','init','-b','main',project])
    (project/'README.md').write_text('Disposable resource-admission launch scenario.\n')
    run(['git','-C',project,'add','README.md'])
    run(['git','-C',project,'-c','user.name=Validation','-c','user.email=validation@example.invalid','commit','-m','fixture'])
    primaryenv=dict(ENV)
    primaryenv.pop('NO_MISTAKES_GATE',None)
    # The tmux server and every pane belong to the lab's private socket.
    run(['tmux','-L','fm-lab','new-session','-d','-x','120','-y','40','-s','primary','-c',ROOT,'-e','FM_HOME='+str(LAB),'codex --disable hooks'],env=primaryenv)
    time.sleep(3)
    tmux('capture-pane','-p','-t','primary')
    ENV['TMUX']=tmux('display-message','-p','-t','primary','#{socket_path},#{pid},0').stdout.strip()
    ENV['TMUX_PANE']=tmux('display-message','-p','-t','primary','#{pane_id}').stdout.strip()
    capacity=LAB/'config/project-capacity'
    capacity.write_text('project 1\n')
    original=capacity.read_bytes()
    for task in ['idle-a','idle-b','light-c','malformed-d','directory-e']:
        if task == 'malformed-d':
            capacity.write_text('project nonsense\nproject 1\nproject 1\n')
            original=capacity.read_bytes()
        if task == 'directory-e':
            capacity.unlink()
            capacity.mkdir()
        run([ROOT/'bin/fm-queue.sh','add',task,'Idle admission proof '+task,'--kind','ship'])
        run([ROOT/'bin/fm-brief.sh',task,'project','--mode','local-only','--project',project])
        brief=LAB/'data'/task/'brief.md'
        text=brief.read_text().replace('{TASK}','For this disposable validation, take no action and wait for a follow-up. Do not edit any file, start any command, or contact any service.').replace('{FIRSTMATE_SPEC}','This scenario only measures whether an idle worker can launch. Stay idle.')
        brief.write_text(text)
        out=run([ROOT/'bin/fm-spawn.sh',task,project,'--mode','local-only','--yolo','off','--harness','codex','--backend','tmux'],timeout=100)
        assert 'spawned '+task in out.stdout
        assert capacity.is_dir() if task == 'directory-e' else capacity.read_bytes()==original
        meta=LAB/'state'/(task+'.meta')
        assert meta.exists()
        print('PUBLISHED TASK RECORD\n'+meta.read_text(),flush=True)
        state=run([ROOT/'bin/fm-queue.sh','show',task])
        assert 'state: in_flight' in state.stdout
    windows=tmux('list-windows','-t','primary','-F','#{window_name} #{pane_current_command} #{pane_current_path}').stdout
    for task in ['idle-a','idle-b','light-c']: assert 'fm-'+task in windows
    for task in ['idle-a','idle-b','light-c']: tmux('capture-pane','-p','-t','primary:fm-'+task)
    print('OBSERVED: three real terminal workers launched for a project declaring legacy capacity=1; all three records and In flight queue rows exist; the declaration bytes remain unchanged. A malformed legacy declaration and a legacy path that is a directory also allow real launches without modification. No directory trust was granted and no model request was needed for this admission proof.',flush=True)
finally:
    if (LAB/'tmux').exists(): tmux('kill-server',check=False)
    time.sleep(.5)
    if LAB.exists():
        for folder, dirs, files in os.walk(LAB):
            os.chmod(folder,0o700)
    if LAB.exists(): shutil.rmtree(LAB)
    if (ROOT/'.validation-tmp/copies').exists(): shutil.rmtree(ROOT/'.validation-tmp/copies')
    print('Removed disposable lab, its private terminal server, task copies, and project.',flush=True)
