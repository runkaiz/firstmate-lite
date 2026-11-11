import os, sys, json, pathlib, subprocess, time, http.server, threading, shlex, secrets, shutil
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M74F8VZ5BTPW2N5AC6ZD1V83'); E=pathlib.Path(sys.argv[1]); W=R/'.lv'; H=R/'l'; C=W/'share/firstmate'
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','TASKS_AXI_','ANTHROPIC_','OPENAI_','CODEX_','CLAUDE_')) or k in ('NO_MISTAKES_GATE','TMUX','CLAUDECODE'):
        env.pop(k,None)
env.update(HOME=str(W/'user'),XDG_DATA_HOME=str(W/'share'),XDG_CONFIG_HOME=str(W/'xdg'),XDG_CACHE_HOME=str(W/'cache'),TMPDIR=str(W/'tmp'),CODEX_HOME=str(W/'codex'),CLAUDE_CONFIG_DIR=str(W/'claude'),PI_CODING_AGENT_DIR=str(W/'pi'),PI_TELEMETRY='0',GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',FM_STARTUP_NETWORK_TIMEOUT='2',FM_BACKEND='tmux',TMUX_TMPDIR=str(H/'tmux'))
(H/'tmux').mkdir(exist_ok=True); (H/'config/supervision-host-off').touch()
log=[]; captures=[]; current=''
class Probe(http.server.BaseHTTPRequestHandler):
    def do_POST(self):
        data=self.rfile.read(int(self.headers.get('Content-Length','0'))).decode()
        captures.append({'cli':current,'path':self.path,'body':data})
        self.send_response(400); self.send_header('Content-Type','application/json'); self.end_headers(); self.wfile.write(b'{"error":{"type":"invalid_request_error","message":"Local discovery probe captured; model responses are intentionally unavailable"}}')
    def log_message(self,*args): pass
server=http.server.ThreadingHTTPServer(('127.0.0.1',0),Probe); threading.Thread(target=server.serve_forever,daemon=True).start(); url='http://127.0.0.1:'+str(server.server_port)
# This key belongs solely to the disposable local probe endpoint, never a provider login.
key=secrets.token_hex(16)
physical_home='/var/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M74F8VZ5BTPW2N5AC6ZD1V83/l'
(W/'codex/config.toml').write_text('model="probe"\nmodel_provider="local-probe"\n[model_providers.local-probe]\nname="Local discovery probe"\nbase_url="'+url+'/v1"\nwire_api="responses"\nrequires_openai_auth=false\nrequest_max_retries=0\nstream_max_retries=0\n[projects."'+str(H)+'"]\ntrust_level="trusted"\n[projects."'+physical_home+'"]\ntrust_level="trusted"\n')
(W/'pi/models.json').write_text(json.dumps({'providers':{'local-probe':{'baseUrl':url+'/v1','api':'openai-completions','apiKey':key,'models':[{'id':'probe','name':'Local discovery probe','reasoning':False,'input':['text'],'cost':{'input':0,'output':0,'cacheRead':0,'cacheWrite':0},'contextWindow':128000,'maxTokens':1000}]}}}))
def run(args,check=True,extra=None):
    p=subprocess.run(['rtk',*map(str,args)],cwd=R,env={**env,**(extra or {})},text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    log.append('$ '+shlex.join(map(str,args))+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
    if check and p.returncode: raise RuntimeError(log[-1])
    return p

def tmux(*args,check=True,extra=None): return run(['tmux','-L','fm-lab',*args],check,extra)
results=[]
try:
    for cli,args in [
      ('codex',['codex','--no-daemon','--dangerously-bypass-hook-trust','exec','--ephemeral','--skip-git-repo-check','$lab-discovery-probe']),
      ('claude',['claude','--setting-sources','project','--strict-mcp-config','--no-session-persistence','--tools','default','--verbose','--output-format','stream-json','--include-hook-events','-p','/lab-discovery-probe']),
      ('pi',['pi','--offline','--approve','--no-session','--no-mcp','--model','local-probe/probe','-p','/skill:lab-discovery-probe'])]:
        current=cli
        # Native startup must make its own fresh completion record for each harness.
        for name in ['.lock','.session-start-complete','.lock-session']:
            (H/'state'/name).unlink(missing_ok=True)
        command=shlex.join([str(H/'bin/fm-start.sh'),*args])+' > '+shlex.quote(str(E/(cli+'-native.log')))+' 2>&1'
        tmux('new-session','-d','-s','primary','-x','120','-y','40','-c',str(R),'-e','FM_HOME='+str(H),command,extra={'ANTHROPIC_BASE_URL':url,'ANTHROPIC_API_KEY':key,'CLAUDE_CODE_DISABLE_NONESSENTIAL_TRAFFIC':'1'})
        start=time.monotonic()
        while time.monotonic()-start < 50:
            if any(x['cli']==cli for x in captures): break
            time.sleep(.25)
        tmux('capture-pane','-p','-t','primary',check=False)
        tmux('kill-server',check=False)
        bodies=[x['body'] for x in captures if x['cli']==cli]
        combined='\n'.join(bodies)
        observed={'cli':cli,'requests':len(bodies),'linked_instructions':'This is the supervisor contract for primary firstmates.' in combined,'linked_skill':'NATIVE_SPLIT_SKILL_7B3A' in combined,'startup_digest':('SESSION START - '+physical_home) in combined,'completion_record':(H/'state/.session-start-complete').exists()}
        (E/(cli+'-request.json')).write_text(json.dumps([dict(path=x['path'],body=json.loads(x['body'])) for x in captures if x['cli']==cli],indent=2))
        results.append(observed); log.append('NATIVE OBSERVATIONS '+json.dumps(observed))
        (E/'native-results.json').write_text(json.dumps(results,indent=2))
    # A worker inheriting a primary environment must not take its session lock or emit the digest.
    worker_home=W/'second home'
    before={p.name:p.read_bytes() for p in (worker_home/'state').iterdir() if p.is_file()}
    p=run([worker_home/'bin/fm-start.sh','bin/fm-sessionstart-run.sh','--source','startup'],extra={'FM_HOME':str(worker_home),'FM_TASK_ID':'disposable-worker'})
    assert not p.stdout
    after={p.name:p.read_bytes() for p in (worker_home/'state').iterdir() if p.is_file()}
    assert before==after
    log.append('WORKER OBSERVED: inherited primary home produced no startup output and changed no state file.')
finally:
    tmux('kill-server',check=False); server.shutdown()
    (E/'native-startup-transcript.log').write_text('\n\n'.join(log)+'\n')
