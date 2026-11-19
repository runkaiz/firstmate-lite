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
w=ROOT/".phase-test/copies/generated/worktree";keep=LAB/"data/generated/preserved-artifacts"
write(w/"node_modules/pkg/index.js","module\n");write(w/"__pycache__/mod.pyc","bytecode\n");write(w/"notes.txt","unique\n")
cli("fm-teardown.sh","generated",ok=1);assert (w/"notes.txt").exists() and not keep.exists();(w/"notes.txt").unlink()
old=(w/"README.md").read_text();write(w/"README.md",old+"unique edit\n");cli("fm-teardown.sh","generated",ok=1);write(w/"README.md",old)
(w/"node_modules/.git").mkdir();cli("fm-teardown.sh","generated",ok=1);(w/"node_modules/.git").rmdir()
cli("fm-teardown.sh","generated");assert not w.exists() and (keep/"files/node_modules/pkg/index.js").read_text()=="module\n"
proof("Real teardown preserves node_modules and __pycache__ in one pass; unknown files, tracked edits and nested repositories refuse without moving output.")
# Cause an actual receipt write failure (directory occupies receipt.tmp), then retry with clean/partial copies.
for kind in ["clean","partial"]:
 task="retry-"+kind;w=alloc(task);keep=LAB/("data/"+task+"/preserved-artifacts")
 write(w/"__pycache__/mod.pyc","bytecode\n")
 if kind=="partial":write(w/"node_modules/pkg/index.js","module\n")
 (keep/"receipt.tmp").mkdir(parents=True)
 cli("fm-teardown.sh",task,ok=1)
 assert not (w/"__pycache__").exists() and (keep/"files/__pycache__/mod.pyc").exists() and w.exists()
 write(keep/"files/__pycache__/mod.pyc","corrupted\n")
 p=cli("fm-teardown.sh",task,ok=1);assert "does not match its journaled manifest" in p.stdout
 assert w.exists() and (LAB/("state/"+task+".meta")).exists()
 write(keep/"files/__pycache__/mod.pyc","bytecode\n");(keep/"receipt.tmp").rmdir()
 cli("fm-teardown.sh",task);assert not w.exists()
 receipt=(keep/"receipt").read_text();assert receipt.count("__pycache__")==1
 if kind=="partial":assert receipt.count("node_modules")==1
 (EVID/(task+"-receipt.txt")).write_text(receipt)
proof("After real receipt-write interruption, clean and partial retries verify journaled custody; corrupted artifacts refuse, restored artifacts retire with exactly one receipt each.")
