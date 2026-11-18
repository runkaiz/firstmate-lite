import os, pathlib, subprocess, time, json, shutil, shlex
root=pathlib.Path.cwd()
base=root/'.quiet-validation'
lab=base/'home'
evidence=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7RER93RQ5FCMJD426B48YQJ')
env=os.environ.copy()
for k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS','FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_TASK_ID']:
    env.pop(k,None)
env['FM_HOME']=str(lab)
env['XDG_RUNTIME_DIR']=str(base/'runtime')
(base/'runtime').mkdir(exist_ok=True)
(lab/'config'/'supervision-host-off').touch()
(lab/'config'/'resource-locks').write_text('quiet-probe 1 isolated validation command\n')
sock=subprocess.check_output(['bin/fm-lab-home.sh','tmux-dir',str(lab)],env=env,text=True).strip()
env['TMUX_TMPDIR']=sock
briefs={}
for kind,args in [('no-mistakes',['--mode','no-mistakes']),('direct-PR',['--mode','direct-PR']),('local-only',['--mode','local-only']),('scout',['--scout'])]:
    task='quiet-timeout-'+kind
    subprocess.run(['bin/fm-brief.sh',task,'sample',*args],env=env,check=True)
    brief=(lab/'data'/task/'brief.md').read_text()
    (evidence/('emitted-'+kind+'-brief.md')).write_text(brief)
    assert 'with one blocking tool call at the longest timeout your shell tool allows' in brief
    assert 'post no progress or "still waiting" text between waits' in brief
    briefs[kind]=brief
status_rules='\n'.join(briefs['scout'].splitlines()[37:46])
(evidence/'consumed-status-rules.txt').write_text(status_rules)
commands={'timeout': 'timeout 5s /var/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7RER93RQ5FCMJD426B48YQJ/bin/fm-resource-lock.sh run quiet-probe -- printf "TIMEOUT_RECOVERY_COMPLETE\\n"'}
try:
  for name,command in commands.items():
    if name=='timeout':
      (lab/'state'/'holder-ready').unlink(missing_ok=True)
      holder=subprocess.Popen(['flock',str(base/'runtime'/'quiet-probe.lock'),'sh','-c','touch "$FM_HOME/state/holder-ready"; sleep 30'],env=env)
      while not (lab/'state'/'holder-ready').exists(): time.sleep(.1)
    prompt=('This is a disposable development evaluation of emitted worker instructions, not a coding assignment. Execute this one harmless command in the current worktree and report its result: '+command+' Retry this exact wrapped command if its timeout expires before it acquires the lock; stop once TIMEOUT_RECOVERY_COMPLETE is printed.\nThe command may take time to complete. Apply the following status instructions emitted by the real Firstmate brief generator. The status file is '+str(lab/'state'/(name+'.status'))+'. All intentional writes must stay in '+str(base)+'. Do not initialize a pipeline or invoke fleet lifecycle.\n'+status_rules)
    (base/(name+'.prompt')).write_text(prompt)
    out=evidence/(name+'-claude-stream.jsonl')
    err=evidence/(name+'-claude-stderr.txt')
    out.write_text('')
    err.write_text('')
    launch=base/(name+'.sh')
    cli=['claude','-p','--setting-sources','','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--no-session-persistence','--tools','Bash','--allowedTools','Bash','--system-prompt','You are a worker performing an isolated development evaluation. Follow the task instructions. You may only use Bash for the assigned command and its status declaration.','--output-format','stream-json','--verbose']
    launch.write_text('#!/bin/bash\n'+shlex.join(cli)+' < '+shlex.quote(str(base/(name+'.prompt')))+' > '+shlex.quote(str(out))+' 2> '+shlex.quote(str(err))+'\nprintf \'CLI_EXIT=%s\\n\' \"$?\" >> '+shlex.quote(str(err))+'\nsleep 3\n')
    subprocess.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(root),'-e','FM_HOME='+str(lab),'bash '+shlex.quote(str(launch))],env=env,check=True)
    start=time.monotonic()
    while time.monotonic()-start<150:
      if out.exists():
        lines=out.read_text().splitlines()
        if any('"type":"result"' in line for line in lines): break
      if subprocess.run(['tmux','-L','fm-lab','has-session','-t','primary'],env=env,stderr=subprocess.DEVNULL).returncode: break
      time.sleep(1)
    subprocess.run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],env=env,stdout=open(evidence/(name+'-pane.txt'),'w'),stderr=subprocess.DEVNULL)
    subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stderr=subprocess.DEVNULL)
    print(name,'elapsed',round(time.monotonic()-start,1),flush=True)
    if name=='timeout': holder.wait(timeout=40)
    if (lab/'state'/(name+'.status')).exists(): shutil.copyfile(lab/'state'/(name+'.status'),evidence/(name+'-status.txt'))
finally:
  subprocess.run(['tmux','-L','fm-lab','kill-server'],env=env,stderr=subprocess.DEVNULL)
  subprocess.run(['bin/fm-lab-home.sh','teardown',str(lab)],env=env,check=True)
