import os,pathlib,subprocess,time,shutil,json,shlex
root=pathlib.Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6DC5VNVA0R6QVNCBPEMJX18")
lab=root/".qa/l"; ev=pathlib.Path("/home/runkai/.no-mistakes/evidence/01M6DC5VNVA0R6QVNCBPEMJX18")
subprocess.run([str(root/"bin/fm-lab-home.sh"),"create",str(lab)],check=True,capture_output=True)
(lab/"tmux").mkdir(); (lab/"tools").mkdir()
for tool in ["codex","node","pi"]:
 p=shutil.which(tool)
 if p: (lab/"tools"/tool).symlink_to(p)
env=dict(os.environ)
for k in list(env):
 if k.startswith("FM_") or k in ["NO_MISTAKES_GATE","TASKS_AXI_FILE","TASKS_AXI_BACKEND"]: env.pop(k,None)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/"tmux"),TMPDIR=str(root/".qa/tmp"),PATH=str(lab/"tools")+":/usr/bin:/bin",GIT_CONFIG_GLOBAL="/dev/null",GIT_CONFIG_NOSYSTEM="1",GIT_AUTHOR_NAME="Lab",GIT_AUTHOR_EMAIL="lab@example.invalid",GIT_COMMITTER_NAME="Lab",GIT_COMMITTER_EMAIL="lab@example.invalid")
logs=[]
def run(args,timeout=90,cwd=root):
 p=subprocess.run(list(map(str,args)),env=env,cwd=cwd,text=True,capture_output=True,timeout=timeout)
 logs.append("$ "+" ".join(map(str,args))+"\n"+p.stdout+p.stderr+f"exit={p.returncode}\n")
 print(p.stdout+p.stderr,flush=True)
 return p
def tmux(*a):return run(["tmux","-L","fm-lab",*a])
try:
 p=tmux("new-session","-d","-s","primary","-x","120","-y","40","-c",str(root),"-e",f"FM_HOME={lab}","codex","--disable","hooks","--sandbox","read-only","--ask-for-approval","never","-c",f"projects.\"{root}\".trust_level=\"trusted\"","Reply exactly LAB_READY. Do not use tools or change files.")
 assert p.returncode==0
 env["TMUX"]=tmux("display-message","-p","-t","primary","#{socket_path},#{pid},0").stdout.strip()
 tmux("set-option","-g","default-command","/bin/bash --noprofile --norc")
 proj=lab/"projects/demo"; proj.mkdir()
 run(["git","init","-q","-b","main",proj])
 (proj/"source.txt").write_text("preserved source\n")
 run(["git","-C",proj,"add","source.txt"]); run(["git","-C",proj,"commit","-qm","baseline"])
 for name,value in [("worktree-allocator","git"),("git-worktree-root",str(root/".qa/copies")),("backlog-backend","manual")]: (lab/"config"/name).write_text(value+"\n")
 (lab/"data/projects.md").write_text("- demo [local-only]\n")
 (lab/"config/crew-dispatch.json").write_text(json.dumps({"default":[{"harness":"codex"},{"harness":"pi","model":"opencode-go/kimi-k3"},{"harness":"pi","model":"opencode-go/beam-free"}]}))
 p=run([root/"bin/fm-brief.sh","quota-live","demo","--mode","local-only","--project",proj]); assert p.returncode==0
 brief=lab/"data/quota-live/brief.md"
 brief.write_text(brief.read_text().replace("{TASK}","Reply exactly WORKER_READY, without using tools or modifying files. This is a disposable runtime launch check.").replace("{FIRSTMATE_SPEC}","Do not invoke a pipeline, git, or any tools. Only reply WORKER_READY and wait."))
 original_brief=brief.read_bytes()
 run([root/"bin/fm-quota-failover.sh","record","--harness","codex","--why","operator-reported lab exhaustion"])
 p=run([root/"bin/fm-spawn.sh","quota-live",proj,"--harness","codex","--mode","local-only","--yolo","off","--backend","tmux"],timeout=120)
 if p.returncode!=0: raise RuntimeError("spawn failed")
 meta=lab/"state/quota-live.meta"; m=dict(line.split("=",1) for line in meta.read_text().splitlines() if "=" in line)
 logs.append("Persisted task metadata:\n"+meta.read_text())
 assert m["harness"]=="pi",m
 assert brief.read_bytes()==original_brief
 time.sleep(3)
 initial=tmux("capture-pane","-p","-t",m["window"])
 if "Trust project folder?" in initial.stdout and "Trust (this session only)" in initial.stdout:
  tmux("send-keys","-t",m["window"],"Down","Down","Enter")
 time.sleep(20)
 p=run([root/"bin/fm-peek.sh","quota-live","45"])
 (ev/"spawn-worker-pane.txt").write_text(p.stdout+p.stderr)
 p=run([root/"bin/fm-quota-failover.sh","relaunch","quota-live"])
 if p.returncode==0:
  logs.append("RECOVERY COMPLETED\n"+meta.read_text())
  replacement=dict(line.split("=",1) for line in meta.read_text().splitlines() if "=" in line)
  assert replacement["worktree"]==m["worktree"] and replacement["model"]=="opencode-go/beam-free"
  assert brief.read_bytes()==original_brief
  time.sleep(10)
  run([root/"bin/fm-peek.sh","quota-live","45"])
  again=run([root/"bin/fm-quota-failover.sh","relaunch","quota-live"])
  assert again.returncode==1 and "already switched" in again.stderr
 elif p.returncode==3:
  assert not (lab/"state/quota-live.quota-failover").exists()
 else: raise RuntimeError("Recovery refused: "+p.stderr)
 run([root/"bin/fm-control.sh","quota-live","exit"],timeout=60)
 (lab/"state/quota-live.quota-failover").write_text("from=pi/default to=codex/default lab cleanup fixture\n")
 (lab/"state/other.quota-failover").write_text("unrelated task\n")
 wt=pathlib.Path(m["worktree"])
 (wt/"unlanded.txt").write_text("preserve unlanded work\n")
 p=run([root/"bin/fm-teardown.sh","quota-live"],timeout=90)
 assert p.returncode!=0 and (lab/"state/quota-live.quota-failover").exists()
 assert (wt/"unlanded.txt").read_text()=="preserve unlanded work\n"
 run(["git","-C",wt,"add","unlanded.txt"]); run(["git","-C",wt,"commit","-qm","lab work"])
 head=run(["git","-C",wt,"rev-parse","HEAD"]).stdout.strip()
 run(["git","-C",proj,"merge","--ff-only",head])
 p=run([root/"bin/fm-teardown.sh","quota-live"],timeout=90)
 assert p.returncode==0,p
 assert not (lab/"state/quota-live.quota-failover").exists()
 assert (lab/"state/other.quota-failover").exists()
 assert not meta.exists() and not wt.exists()
 logs.append("Verified: real Pi selected/launched from recorded Codex exhaustion; brief/source retained; recovery result above; unlanded teardown retained marker; landed teardown removed only retired task marker.\n")
 print(logs[-1])
finally:
 tmux("kill-server")
 (ev/"live-spawn-teardown.log").write_text("\n".join(logs))
 for base,ds,fs in os.walk(lab): os.chmod(base,0o700)
 shutil.rmtree(lab)
 shutil.rmtree(root/".qa/copies",ignore_errors=True)
 print("Lab server and home removed",flush=True)
