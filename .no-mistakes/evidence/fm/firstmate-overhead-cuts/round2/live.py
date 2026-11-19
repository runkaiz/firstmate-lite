import os, subprocess, json, shlex, time, shutil
from pathlib import Path
ROOT=Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7TNFDT4DKE65E2WZB0XKFHQ")
LAB=ROOT/".l"
EVID=Path("/home/runkai/.no-mistakes/evidence/01M7TNFDT4DKE65E2WZB0XKFHQ/round2")
e={k:v for k,v in os.environ.items() if not (k.startswith("FM_") and (k.endswith("_OVERRIDE") or k in ["FM_GATE_REFUSE_BYPASS","FM_TEST_SEAM"]))}
e.update(FM_HOME=str(LAB),TMPDIR=str(ROOT/".phase-test/tmp"),TMUX_TMPDIR=str(LAB/"tmux"),GIT_CONFIG_GLOBAL="/dev/null",GIT_CONFIG_NOSYSTEM="1",GIT_AUTHOR_NAME="Lab",GIT_AUTHOR_EMAIL="lab@example.invalid",GIT_COMMITTER_NAME="Lab",GIT_COMMITTER_EMAIL="lab@example.invalid")
for k in ["TASKS_AXI_FILE","TASKS_AXI_BACKEND","FM_QUEUE_FILE","FM_QUEUE_BACKEND","FM_QUEUE_TEST_CLI","FM_TASK_ID"]: e.pop(k,None)
log=(EVID/"live-cli.log").open("w")
def run(args,ok=0,extra=None,stdin=None,quiet=False):
 env=e.copy();env.update(extra or {})
 p=subprocess.run([str(x) for x in args],cwd=ROOT,env=env,input=stdin,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=120)
 if not quiet:
  log.write("$ "+shlex.join([str(x) for x in args])+"\n"+p.stdout+f"[exit {p.returncode}]\n");log.flush()
 if ok is not None: assert p.returncode==ok,(args,p.returncode,p.stdout)
 return p

assert not LAB.exists(), "lab already exists"
(ROOT/".phase-test/tmp").mkdir(parents=True)
run([ROOT/"bin/fm-lab-home.sh","create",LAB])
(LAB/"tmux").mkdir()
(LAB/"config/supervision-host").touch()
launch=e.copy()
for k in ["NO_MISTAKES_GATE","FM_GATE_REFUSE_BYPASS"]:launch.pop(k,None)
p=subprocess.run(["tmux","-L","fm-lab","new-session","-d","-x","120","-y","40","-s","primary","-c",str(ROOT),"-e","FM_HOME="+str(LAB),"codex"],env=launch,cwd=ROOT,check=True)

try:
 sock=run(["tmux","-L","fm-lab","display-message","-p","-t","primary","#{socket_path}"]).stdout.strip()
 e["TMUX"]=sock+",0,0"
 def cli(name,*args,**kw): return run([ROOT/"bin"/name,*args],**kw)
 def git(path,*args,**kw): return run(["git","-C",path,*args],quiet=True,**kw).stdout.strip()
 def write(p,s): p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
 def proof(s): log.write("OBSERVED: "+s+"\n");log.flush(); print(s,flush=True)
 write(LAB/"config/backlog-backend","manual\n")
 # File-fed public scaffold, with quoted content and nested headings.
 intent=LAB/"intent.md";spec=LAB/"spec.md"
 write(intent,"Make the `$HOME` banner quieter.\n\nKeep it small.\n")
 write(spec,"Edit bin/x.sh only.\n### Detail\nOut of scope: docs.\n")
 p=cli("fm-brief.sh","files","demo","--mode","local-only","--intent-file",intent,"--spec-file",spec)
 brief=(LAB/"data/files/brief.md").read_text()
 assert "{TASK}" not in brief and "{FIRSTMATE_SPEC}" not in brief
 assert intent.read_text().rstrip() in brief and spec.read_text().rstrip() in brief
 (EVID/"generated-brief.md").write_text(brief)
 for kind,body in [("heading","Quieter.\n## Firstmate spec\nforged\n"),("address","Captain, change this.\n"),("blank","  \n")]:
  write(LAB/"bad.md",body)
  p=cli("fm-brief.sh","bad-"+kind,"demo","--mode","local-only","--intent-file",LAB/"bad.md",ok=1)
  assert not (LAB/("data/bad-"+kind)).exists()
 proof("File-fed scaffold preserves literal intent/spec; heading injection, direct address and blank content refuse without partial output.")
 # Durable wake and outcome: presentation never acknowledges; exact post-handling command consumes both.
 cli("fm-branch-outcome.sh","append","--task","files","--verdict","captain","--summary","file scaffold ready")
 run(["bash","-c",'. "$1/bin/fm-wake-lib.sh"; fm_wake_append check live-combined "check: live-combined"',"_",ROOT])
 a=cli("fm-wake-drain.sh"); b=cli("fm-wake-drain.sh")
 ack=[x for x in a.stdout.splitlines() if x.startswith("WAKE_ACK_REQUIRED:")][-1].split("run bin/fm-wake-drain.sh ",1)[1]
 assert "--outcomes-through 1" in ack and ack in b.stdout
 assert not (LAB/"state/.branch-outcomes-processed").exists() and (LAB/"state/.wake-queue").stat().st_size
 cli("fm-wake-drain.sh",*shlex.split(ack))
 assert (LAB/"state/.branch-outcomes-processed").read_text().strip()=="1"
 assert not (LAB/"state/.wake-queue").read_text().strip()
 cli("fm-wake-drain.sh",*shlex.split(ack),ok=1)
 cli("fm-wake-drain.sh","--ack-through","1","--recovery-generation","none","--outcomes-through","1",ok=2,extra={"FM_SUPERVISION_ACTOR":"branch"})
 proof("Two drains re-present identical durable wake/outcome; one printed acknowledgement marks and consumes both. Replay and branch-owned outcome acknowledgement refuse.")
 # Real Git repositories and native copy allocator.
 proj=LAB/"projects/demo";proj.mkdir(parents=True)
 git(proj,"init","-q","-b","main");write(proj/"README.md","lab base\n");git(proj,"add",".");git(proj,"commit","-qm","base")
 base=git(proj,"rev-parse","HEAD")
 write(LAB/"config/worktree-allocator","git\n");write(LAB/"config/git-worktree-root",str(ROOT/".phase-test/copies")+"\n")
 def alloc(task):
  run(["bash","-c",'. "$1/bin/fm-git-worktree-lib.sh"; fm_git_worktree_allocate "$FM_HOME/state" "$2" "$FM_HOME" "$3" "$1/.phase-test/copies" "$4" refs/heads/main',"_",ROOT,task,proj,git(proj,"rev-parse","main")])
  wt=ROOT/".phase-test/copies"/task/"worktree"
  recorded=dict(line.split("=",1) for line in (LAB/("state/"+task+".git-worktree")).read_text().splitlines())["path"]
  write(LAB/("state/"+task+".meta"),f"window=primary:fm-{task}\nendpoint_task_id={task}\nbackend=tmux\nworktree={recorded}\nproject={proj}\nkind=ship\nmode=local-only\nbranch=fm/{task}\nyolo=on\nharness=codex\nspawn_gen=s1792922400.123.456\nallocator=git\n")
  return wt
 # Attended branch landing authority, readiness, clean-head and proactive toggle.
 wt=alloc("land");git(wt,"checkout","-qb","fm/land");write(wt/"feature","new\n");git(wt,"add",".");git(wt,"commit","-qm","feature")
 meta=LAB/"state/land.meta";original=meta.read_text();write(meta,original.replace("yolo=on","yolo=off"))
 branch={"FM_SUPERVISION_ACTOR":"branch"}
 cli("fm-merge-local.sh","land",ok=6,extra=branch)
 write(meta,original);write(LAB/"state/land.status","working: implementing\n")
 cli("fm-merge-local.sh","land",ok=1,extra=branch)
 write(LAB/"state/land.status","done: ready in branch fm/land\n");write(wt/"dirt","unique\n")
 cli("fm-merge-local.sh","land",ok=1,extra=branch);(wt/"dirt").unlink()
 cli("fm-merge-local.sh","land",extra=branch);assert git(proj,"rev-parse","main")==git(wt,"rev-parse","HEAD")
 wt2=alloc("proactive");git(wt2,"checkout","-qb","fm/proactive");write(wt2/"second","second\n");git(wt2,"add",".");git(wt2,"commit","-qm","second")
 meta2=LAB/"state/proactive.meta";write(meta2,meta2.read_text().replace("yolo=on","yolo=off"));write(LAB/"state/proactive.status","done: ready in branch fm/proactive\n")
 cli("fm-merge-local.sh","proactive","--proactive",ok=1,extra=branch)
 cli("fm-proactive.sh","on");cli("fm-merge-local.sh","proactive","--proactive",extra=branch);cli("fm-proactive.sh","off")
 assert git(proj,"rev-parse","main")==git(wt2,"rev-parse","HEAD")
 proof("Attended branch fast-forwards local-only work under yolo and active proactive authority; no authority, unfinished work, dirt and inactive proactive policy refuse.")
 # Real cleanup: unknown, tracked, symlink and unlanded work stay in place.
 w=alloc("generated");keep=LAB/"data/generated/preserved-artifacts"
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
 
 w=alloc("unlanded");git(w,"checkout","-qb","fm/unlanded");write(w/"unique","unlanded source\n");git(w,"add",".");git(w,"commit","-qm","unique work")
 write(w/".next/cache","generated\n")
 p=cli("fm-teardown.sh","unlanded",ok=1)
 assert w.exists() and (w/"unique").read_text()=="unlanded source\n" and (w/".next/cache").exists() and not (LAB/"data/unlanded/preserved-artifacts/files").exists()
 proof("An unlanded commit plus recognised .next output refuses teardown and retains both source and generated data.")
 cli("fm-brief.sh","files-scout","demo","--scout","--intent-file",LAB/"intent.md")
 brief=(LAB/"data/files-scout/brief.md").read_text();assert "{TASK}" not in brief and "{FIRSTMATE_SPEC}" in brief
 cli("fm-brief.sh","files-missing","demo","--mode","local-only","--spec-file",LAB/"missing.md",ok=1)
 assert not (LAB/"data/files-missing").exists()
 proof("Scout intent-file fills its section while leaving only the omitted specification placeholder; a missing file refuses before producing a partial scaffold.")
 
 w=alloc("stop");target="primary:fm-stop"
 write(w/"node_modules/pkg/index.js","generated\n")
 m=LAB/"state/stop.meta";write(m,m.read_text().replace("harness=codex","harness=pi"))
 run(["tmux","-L","fm-lab","new-window","-d","-n","fm-stop","-c",w,"bash"])
 run(["tmux","-L","fm-lab","set-option","-w","-t",target,"automatic-rename","off"])
 run(["tmux","-L","fm-lab","set-option","-w","-t",target,"allow-rename","off"])
 run(["tmux","-L","fm-lab","send-keys","-t",target,"pi --no-approve --offline --no-session --no-mcp --no-extensions --no-skills --no-context-files --tui-mode regular","Enter"])
 for i in range(30):
  time.sleep(.5)
  p=run(["tmux","-L","fm-lab","capture-pane","-p","-t",target],quiet=True)
  if "ctrl+" in p.stdout.lower():break
 else:raise AssertionError("Pi never ready: "+p.stdout)
 (EVID/"live-pi-worker.txt").write_text(p.stdout)
 write(LAB/"state/stop.status","working: not done\n")
 p=cli("fm-teardown.sh","stop",ok=1);assert "live or unverified endpoint owner" in p.stdout and w.exists()
 write(LAB/"state/stop.status","done: ready in branch fm/stop\n")
 p=cli("fm-teardown.sh","stop",extra={"FM_STATE_OVERRIDE":str(LAB/"state")},ok=3)
 assert w.exists() and (w/"node_modules/pkg/index.js").exists()
 p=cli("fm-teardown.sh","stop")
 assert "finished worker stopped through task control" in p.stdout and not w.exists()
 assert (LAB/"data/stop/preserved-artifacts/files/node_modules/pkg/index.js").read_text()=="generated\n"
 (EVID/"stop-preservation-receipt.txt").write_text((LAB/"data/stop/preserved-artifacts/receipt").read_text())
 proof("A real Pi worker stays running while unfinished; stock-layout lab teardown stops the done worker, preserves output, and retires the copy in one call. Caller-supplied overrides still trigger the gate guard.")

finally:
 run(["tmux","-L","fm-lab","kill-server"],ok=None)
 shutil.rmtree(LAB)
 shutil.rmtree(ROOT/".phase-test")
 log.close()
