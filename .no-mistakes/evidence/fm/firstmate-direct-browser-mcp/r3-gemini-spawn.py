import os, pathlib, subprocess, json, time, shutil
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6DETVKKZ59NZBMVZXJ557KK')
d=root/'.browser-validation'; lab=d/'gemini-lab'; ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M6DETVKKZ59NZBMVZXJ557KK')
log=open(ev/'r3-gemini-spawn.log','w',buffering=1)
env=dict(os.environ)
for k in list(env):
 if k.startswith(('FM_', 'HERDR_', 'GEMINI_', 'GOOGLE_', 'XDG_')) or k in ['TMUX','TMUX_PANE','NO_MISTAKES_GATE','TMPDIR','NODE_OPTIONS']:env.pop(k,None)
env.update(FM_HOME=str(lab),HOME=str(d/'gemini-user'),PATH=str(d/'node_modules/.bin')+':'+env['PATH'],GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GEMINI_CLI_TRUST_WORKSPACE='true')
pathlib.Path(env['HOME']).mkdir(exist_ok=True)
socket=str(root/'.gm-sock')
def run(cmd, timeout=90):
 p=subprocess.run([str(x) for x in cmd],env=env,cwd=root,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=timeout)
 print('$ '+' '.join(map(str,cmd))+'\n'+p.stdout,file=log)
 return p
assert run([root/'bin/fm-lab-home.sh','create',lab]).returncode==0
for name,value in {'backend':'tmux','backlog-backend':'manual','worktree-allocator':'git','git-worktree-root':str(d/'gemini-copies')}.items():(lab/'config'/name).write_text(value+'\n')
(lab/'data/projects.md').write_text('- project [local-only]\n')
(lab/'state/.last-watcher-beat').touch()
assert run(['tmux','-S',socket,'new-session','-d','-s','fm-lab-gemini','-x','120','-y','40','-c',d,'sleep 600']).returncode==0
env['TMUX']=socket+',0,0'
try:
 for mode in ['valid','invalid','absent']:
  cfg=lab/'config/browser-mcp'
  if mode=='absent':cfg.unlink()
  else:
   value=(d/'browser-mcp').read_text()
   if mode=='invalid':value='\n'.join('chrome_sha256='+'0'*64 if x.startswith('chrome_sha256=') else x for x in value.splitlines())+'\n'
   cfg.write_text(value)
  task='gemini-'+mode; brief=lab/'data'/task/'brief.md';brief.parent.mkdir(parents=True)
  brief.write_text("# Task\n## Captain's intent\nValidate the generated launch interface only. Do not modify files or call external services.\n\n## Firstmate spec\nReport the available browser tools, then stop.\n")
  p=run([root/'bin/fm-spawn.sh',task,d/'project','--mode','local-only','--yolo','off','--harness','gemini','--backend','tmux'])
  assert p.returncode==0,p.stdout
  generated=(lab/'data'/task/'launch-brief.md').read_text()
  notice=next(x for x in generated.splitlines() if x.startswith('Browser tools ('))
  assert 'No browser tool is supplied by this launch on this runtime.' in notice,notice
  settings=lab/'state'/f'{task}.gemini-settings.json'
  if not settings.exists():
   matches=list((lab/'state').glob(task+'*settings*'));assert len(matches)==1,matches;settings=matches[0]
  data=json.loads(settings.read_text());assert 'browser' not in data.get('mcpServers',{}),data
  print(json.dumps({'scenario':mode,'notice':notice,'mcpServers':data.get('mcpServers',{}),'hooks':list(data.get('hooks',{}))}),file=log)
  clientenv=dict(env,GEMINI_CLI_SYSTEM_SETTINGS_PATH=str(settings))
  q=subprocess.run([str(d/'node_modules/.bin/gemini'),'mcp','list'],env=clientenv,cwd=d/'project',stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=30)
  print(q.stdout,file=log);assert q.returncode==0 and 'No MCP servers configured' in q.stdout
  print('PASS actual fm-spawn Gemini '+mode+' pins: no browser wiring and honest emitted notice',file=log)
finally:
 run(['tmux','-S',socket,'kill-server'])
