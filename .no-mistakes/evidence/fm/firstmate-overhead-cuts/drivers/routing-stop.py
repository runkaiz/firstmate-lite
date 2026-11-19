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

# A disposable captured CI monitor failure is consumed through the real host dispatch CLI.
worker="route";snap=LAB/"data/route/findings.txt"
write(LAB/"state/route.meta",f"window=primary:fm-route\nkind=ship\nproject={proj}\nbackend=tmux\nharness=codex\n")
inbox=LAB/"state/procevent-inbox";inbox.mkdir(exist_ok=True)
write(inbox/"ci-route.7.adapter","ci\n");write(inbox/"ci-route.7.result","ci_wait: monitor-error\ntask: route\nrun_id: disposable\nevidence:\nconnection unavailable\n")
write(LAB/"state/.wake-queue","1\t101\tcheck\tprocevent:ci-route:7\tcheck: procevent ci ci-route 7\n")
p=cli("fm-branch-dispatch.mjs","offer",stdin="check: procevent ci ci-route 7\n");assert "eligible=1" in p.stdout and "tasks=route" in p.stdout
cli("fm-send.sh","route","CI monitor failed: connection unavailable. Inspect the captured evidence and reattach your existing run.",extra={"FM_SUPERVISION_ACTOR":"branch"})
assert (LAB/"state/route.inbox/001.msg").exists()
(EVID/"ci-worker-inbox.txt").write_text((LAB/"state/route.inbox/001.msg").read_text())
for field,text in [("result","ci_wait: action\ntask: route\n"),("adapter","when\n")]:
 write(inbox/("ci-route.7."+field),text)
 p=cli("fm-branch-dispatch.mjs","offer",stdin="check: procevent ci ci-route 7\n");assert "eligible=0" in p.stdout
 write(inbox/"ci-route.7.adapter","ci\n");write(inbox/"ci-route.7.result","ci_wait: monitor-error\ntask: route\n")
proof("Host dispatch offers a known worker CI monitor-error to supervision, steering persists in its real inbox, and action/non-CI captures remain main-owned.")
# Pure no-surface test gate routes and accepts only approve. No pipeline command is executed.
q="this change has no live-validatable surface; proceed without live validation? (0 of 1 scenarios were driven live against the product); docs only"
write(snap,"id: test-1\nseverity: warning\ndescription: "+q+"\nauthority: ask-user\n")
status=LAB/"state/route.status"
write(status,f"needs-decision [key=nm-LAB-test]: ask-user findings=test-1 file={snap}\n")
write(LAB/"state/.wake-queue","1\t102\tsignal\troute.status\tneeds-decision: route.status\n")
p=cli("fm-branch-dispatch.mjs","offer",stdin=f"signal: {status}\n");assert "eligible=1" in p.stdout
for act in ["skip","fix"]:
 cli("fm-send.sh","route","--resolve-key","nm-LAB-test","run no-mistakes axi respond --step test --action "+act,ok=6,extra={"FM_SUPERVISION_ACTOR":"branch"})
write(snap,snap.read_text()+"\nid: test-2\ndescription: live validation verdict: inconclusive\nauthority: ask-user\n")
p=cli("fm-branch-dispatch.mjs","offer",stdin=f"signal: {status}\n");assert "eligible=0" in p.stdout
cli("fm-send.sh","route","--resolve-key","nm-LAB-test","run no-mistakes axi respond --step test --action approve",ok=6,extra={"FM_SUPERVISION_ACTOR":"branch"})
write(snap,"id: test-1\ndescription: "+q+"\nauthority: ask-user\n")
cli("fm-send.sh","route","--resolve-key","nm-LAB-test","run no-mistakes axi respond --step test --action approve --reason 'docs only'",extra={"FM_SUPERVISION_ACTOR":"branch"})
assert "resolved [" in status.read_text() and "--action approve" in (LAB/"state/route.inbox/002.msg").read_text()
(EVID/"routine-gate-status.txt").write_text(status.read_text())
(EVID/"routine-gate-inbox.txt").write_text((LAB/"state/route.inbox/002.msg").read_text())
proof("Pure no-surface test decision routes to supervision and approve closes it after durable enqueue; skip, fix and mixed findings refuse before delivery.")
# Live harness process on the same private tmux server, with a non-zero TUI grid.
w=alloc("stop");write(w/"node_modules/pkg/index.js","generated\n")
target="primary:fm-stop"
run(["tmux","-L","fm-lab","new-window","-d","-n","fm-stop","-c",w,"-e","FM_HOME="+str(LAB),"codex"])
run(["tmux","-L","fm-lab","set-option","-w","-t",target,"automatic-rename","off"])
run(["tmux","-L","fm-lab","set-option","-w","-t",target,"allow-rename","off"])
for i in range(30):
 time.sleep(.5)
 p=run(["tmux","-L","fm-lab","capture-pane","-p","-t",target],quiet=True)
 if "Update now" in p.stdout or "Hooks need review" in p.stdout:
  run(["tmux","-L","fm-lab","send-keys","-t",target,"Escape"],quiet=True)
 if "Ask Codex" in p.stdout:break
else:raise AssertionError("Codex worker never reached composer: "+p.stdout)
(EVID/"live-codex-worker.txt").write_text(p.stdout)
write(LAB/"state/stop.status","working: not done\n")
p=cli("fm-teardown.sh","stop",ok=1);assert "live or unverified endpoint owner" in p.stdout and w.exists()
write(LAB/"state/stop.status","done: ready in branch fm/stop\n")
p=cli("fm-teardown.sh","stop",ok=None)
assert p.returncode==0,p.stdout
assert "finished worker stopped through task control" in p.stdout and not w.exists()
assert (LAB/"data/stop/preserved-artifacts/files/node_modules/pkg/index.js").read_text()=="generated\n"
proof("A real Codex TUI is retained while unfinished; one teardown call stops the finished CLI through real task control, preserves generated output and retires the copy.")
