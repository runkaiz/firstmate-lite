import os, subprocess, json, shlex, time, shutil
from pathlib import Path
ROOT=Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7TNFDT4DKE65E2WZB0XKFHQ")
LAB=ROOT/".l"
EVID=Path("/home/runkai/.no-mistakes/evidence/01M7TNFDT4DKE65E2WZB0XKFHQ")
e={k:v for k,v in os.environ.items() if not (k.startswith("FM_") and (k.endswith("_OVERRIDE") or k in ["FM_GATE_REFUSE_BYPASS","FM_TEST_SEAM"]))}
e.update(FM_HOME=str(LAB),TMPDIR=str(ROOT/".phase-test/tmp"),TMUX_TMPDIR=str(LAB/"tmux"),GIT_CONFIG_GLOBAL="/dev/null",GIT_CONFIG_NOSYSTEM="1",GIT_AUTHOR_NAME="Lab",GIT_AUTHOR_EMAIL="lab@example.invalid",GIT_COMMITTER_NAME="Lab",GIT_COMMITTER_EMAIL="lab@example.invalid")
for k in ["TASKS_AXI_FILE","TASKS_AXI_BACKEND","FM_QUEUE_FILE","FM_QUEUE_BACKEND","FM_QUEUE_TEST_CLI","FM_TASK_ID"]: e.pop(k,None)
log=(EVID/"live-cli.log").open("a")
def run(args,ok=0,extra=None,stdin=None,quiet=False):
 env=e.copy();env.update(extra or {})
 p=subprocess.run([str(x) for x in args],cwd=ROOT,env=env,input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 if not quiet:
  log.write("$ "+shlex.join([str(x) for x in args])+"\n"+p.stdout+f"[exit {p.returncode}]\n");log.flush()
 if ok is not None: assert p.returncode==ok,(args,p.returncode,p.stdout)
 return p
sock=run(["tmux","-L","fm-lab","display-message","-p","-t","primary","#{socket_path}"]).stdout.strip()
e["TMUX"]=sock+",0,0"
def cli(name,*args,**kw): return run([ROOT/"bin"/name,*args],**kw)
def git(path,*args,**kw): return run(["git","-C",path,*args],quiet=True,**kw).stdout.strip()
def write(p,s): p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
def proof(s): log.write("OBSERVED: "+s+"\n");log.flush(); print(s,flush=True)
write(LAB/"config/backlog-backend","manual\n")
proj=LAB/"projects/demo"
base=git(proj,"rev-parse","HEAD")
write(LAB/"config/worktree-allocator","git\n");write(LAB/"config/git-worktree-root",str(ROOT/".phase-test/copies")+"\n")
def alloc(task):
 run(["bash","-c",'. "$1/bin/fm-git-worktree-lib.sh"; fm_git_worktree_allocate "$FM_HOME/state" "$2" "$FM_HOME" "$3" "$1/.phase-test/copies" "$4" refs/heads/main',"_",ROOT,task,proj,git(proj,"rev-parse","main")])
 wt=ROOT/".phase-test/copies"/task/"worktree"
 recorded=dict(line.split("=",1) for line in (LAB/("state/"+task+".git-worktree")).read_text().splitlines())["path"]
 write(LAB/("state/"+task+".meta"),f"window=primary:fm-{task}\nendpoint_task_id={task}\nbackend=tmux\nworktree={recorded}\nproject={proj}\nkind=ship\nmode=local-only\nbranch=fm/{task}\nyolo=on\nharness=codex\nspawn_gen=s1792922400.123.456\nallocator=git\n")
 return wt

w=ROOT/".phase-test/copies/stop/worktree";target="primary:fm-stop"

# A process-scoped CLI override avoids saving trust in user configuration.
m=LAB/"state/stop.meta";write(m,m.read_text().replace("harness=codex","harness=pi"))
run(["tmux","-L","fm-lab","new-window","-d","-n","fm-stop","-c",w,"bash"])
run(["tmux","-L","fm-lab","set-option","-w","-t",target,"automatic-rename","off"])
run(["tmux","-L","fm-lab","set-option","-w","-t",target,"allow-rename","off"])
run(["tmux","-L","fm-lab","send-keys","-t",target,"pi --no-approve --offline --no-session --no-mcp --no-extensions --no-skills --no-context-files --tui-mode regular","Enter"])
for i in range(30):
 time.sleep(.5)
 p=run(["tmux","-L","fm-lab","capture-pane","-p","-t",target],quiet=True)
 if "Update now" in p.stdout or "Hooks need review" in p.stdout:
  run(["tmux","-L","fm-lab","send-keys","-t",target,"Escape"],quiet=True)
 if "ctrl+c" in p.stdout.lower() or "ctrl+" in p.stdout.lower():break
else:raise AssertionError("Pi never ready: "+p.stdout)
(EVID/"live-pi-worker.txt").write_text(p.stdout)
write(LAB/"state/stop.status","working: not done\n")
p=cli("fm-teardown.sh","stop",ok=1);assert "live or unverified endpoint owner" in p.stdout and w.exists()
write(LAB/"state/stop.status","done: ready in branch fm/stop\n")
p=cli("fm-teardown.sh","stop",ok=None)
assert p.returncode==1 and "NO_MISTAKES_GATE set" in p.stdout,p.stdout
proof("Confirmed automatic stop fails in a marked lab: its internal path overrides trigger the gate refusal while the real Pi worker stays live.")
p=cli("fm-control.sh","stop","exit");proof("Direct control against the same marked lab stops the real Pi CLI successfully without injected path overrides.")
p=cli("fm-teardown.sh","stop");assert p.returncode==0,p.stdout
assert not w.exists()
assert (LAB/"data/stop/preserved-artifacts/files/node_modules/pkg/index.js").read_text()=="generated\n"
proof("After a separate direct stop, teardown preserves generated output and retires the copy; one-call stop failed in the supported gate lab.")
