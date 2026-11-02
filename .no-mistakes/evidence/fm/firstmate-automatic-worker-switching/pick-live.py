import os,json,subprocess,pathlib,shutil
root=pathlib.Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6DC5VNVA0R6QVNCBPEMJX18")
evidence=pathlib.Path("/home/runkai/.no-mistakes/evidence/01M6DC5VNVA0R6QVNCBPEMJX18")
lab=root/".qa/pick"
subprocess.run([str(root/"bin/fm-lab-home.sh"),"create",str(lab)],check=True,capture_output=True)
env={k:v for k,v in os.environ.items() if not k.startswith("FM_") and k not in ["CODEX_HOME","CLAUDE_CONFIG_DIR","PI_CODING_AGENT_DIR"]}
env.update(FM_HOME=str(lab),HOME=str(lab),PATH="/usr/bin:/bin",TMPDIR=str(root/".qa/tmp"))
log=[]
def call(*args,code=0,contains=None):
 p=subprocess.run([str(root/"bin/fm-quota-failover.sh"),*args],env=env,text=True,capture_output=True)
 log.append("$ fm-quota-failover.sh "+" ".join(args)+"\n"+p.stdout+p.stderr+f"exit={p.returncode}\n")
 assert p.returncode==code,(args,p.returncode,p.stderr)
 if contains is not None: assert contains in p.stdout+p.stderr,(args,p.stdout,p.stderr)
 return p
config=lab/"config/crew-dispatch.json"
def dispatch(value): config.write_text(json.dumps(value))
pair=[dict(harness="codex",model="model-a"),dict(harness="pi",model="provider/model-b")]
try:
 dispatch(dict(default=pair))
 call("pick","--harness","codex","--model","model-a",contains="codex|model-a|")
 call("record","--harness","codex","--model","model-a","--why","disposable lab reported exhaustion")
 call("pick","--harness","codex","--model","model-a",contains="pi|provider/model-b|")
 call("pick","--harness","codex","--model","model-other",contains="codex|model-other|")
 env["CODEX_HOME"]=str(lab/"other-account")
 call("pick","--harness","codex","--model","model-a",contains="codex|model-a|")
 del env["CODEX_HOME"]
 call("record","--harness","pi","--model","provider/model-b")
 call("pick","--harness","codex","--model","model-a",code=75,contains="deferred:")
 for cfg in [dict(default=pair[0]),dict(default=[pair[1]]),dict(rules=[dict(use=pair),dict(use=pair)]),dict(rules=[dict(use=pair)],default=pair)]:
  dispatch(cfg)
  call("pick","--harness","codex","--model","model-a",code=75,contains="no configured alternative")
 call("record","--harness","codex","--model","expired","--until","1")
 call("pick","--harness","codex","--model","expired",contains="codex|expired|")
 (lab/"account-a").mkdir(); (lab/"account-b").mkdir()
 dispatch(dict(default=[dict(harness="claude",model="scoped"),dict(harness="codex",model="healthy")]))
 pin=lab/"config/claude-account"
 pin.write_text(str(lab/"account-a")+"\n")
 call("record","--harness","claude","--model","scoped")
 call("pick","--harness","claude","--model","scoped",contains="codex|healthy|")
 assert pin.read_text()==str(lab/"account-a")+"\n"
 pin.write_text(str(lab/"account-b")+"\n")
 call("pick","--harness","claude","--model","scoped",contains="claude|scoped|")
 (lab/"state/once.meta").write_text("kind=ship\nharness=codex\nmodel=model-a\n")
 (lab/"state/once.quota-failover").write_text("completed prior switch\n")
 call("relaunch","once",code=1,contains="already switched runtime once")
 log.append("Persisted scope records:\n"+(lab/"state/quota-failures").read_text())
 log.append("All public CLI assertions passed. No quota-axi executable was supplied; unavailable evidence stayed unknown. No lifecycle command or external account was stubbed.\n")
finally:
 (evidence/"live-selection.log").write_text("\n".join(log))
 shutil.rmtree(lab)
print(log[-2] if len(log)>1 else log)
print("Transcript: live-selection.log; disposable home removed")
