import subprocess,os,json,time,pathlib
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6DETVKKZ59NZBMVZXJ557KK')
d=root/'.browser-validation'; lab=d/'lab'; wt=d/'copies/browser-cleanup/worktree'
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M6DETVKKZ59NZBMVZXJ557KK')
log=open(ev/'teardown-live.log','w',buffering=1)
env=dict(os.environ)
for k in ['FM_ROOT_OVERRIDE','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','FM_GATE_REFUSE_BYPASS','FM_TASK_ID','NO_MISTAKES_GATE','TMPDIR']:env.pop(k,None)
env.update(FM_HOME=str(lab),TMUX=f'{root}/.browser-socket,0,0',GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1')
servers=[]
def server(cwd):
 p=subprocess.Popen([str(root/'bin/fm-browser-mcp.sh'),str(d/'browser-mcp')],cwd=cwd,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=log,text=True);servers.append(p)
 def rpc(i,method,params):
  p.stdin.write(json.dumps(dict(jsonrpc='2.0',id=i,method=method,params=params))+'\n');p.stdin.flush()
  while True:
   line=p.stdout.readline()
   if not line:raise RuntimeError('MCP exited')
   m=json.loads(line)
   if m.get('id')==i:return m
 rpc(1,'initialize',dict(protocolVersion='2025-06-18',capabilities={},clientInfo=dict(name='cleanup-test',version='1')))
 p.stdin.write(json.dumps(dict(jsonrpc='2.0',method='notifications/initialized'))+'\n');p.stdin.flush()
 result=rpc(2,'tools/call',dict(name='navigate_page',arguments=dict(url='data:text/html,<title>Cleanup proof</title>')))
 assert not result['result'].get('isError'),result
 print(f'Browser server {p.pid} cwd={cwd}: {result}',file=log)
 return p,rpc
def teardown():
 p=subprocess.run([str(root/'bin/fm-teardown.sh'),'browser-cleanup'],cwd=root,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=50)
 print(f'TEARDOWN exit={p.returncode}\n{p.stdout}',file=log);return p
other=None
try:
 a,_=server(wt); b,brpc=server(d/'worker-b')
 other=subprocess.Popen(['sleep','300'],cwd=wt)
 result=teardown()
 assert result.returncode!=0
 assert 'stopping task-owned browser MCP' in result.stdout,result.stdout
 assert other.poll() is None
 assert b.poll() is None
 a.wait(timeout=5)
 assert wt.exists()
 print('PASS refuses remaining unrelated process; owned browser stopped; foreign browser survives',file=log)
 other.terminate();other.wait()
 c,_=server(wt)
 result=teardown();assert result.returncode==0,result.stdout
 c.wait(timeout=5)
 assert not wt.exists()
 assert b.poll() is None
 r=brpc(3,'tools/call',dict(name='evaluate_script',arguments=dict(function='() => document.title')))
 assert 'Cleanup proof' in json.dumps(r)
 print('PASS cleanup removes the task copy and server while foreign browser remains usable',file=log)
finally:
 if other and other.poll() is None:other.terminate();other.wait()
 for p in servers:
  if p.poll() is None:p.stdin.close();p.wait(timeout=15)
 subprocess.run(['tmux','-S',str(root/'.browser-socket'),'kill-server'],stdout=log,stderr=log)
