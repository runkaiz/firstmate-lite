import os, subprocess, tempfile, pathlib, shutil, json, time
ROOT=pathlib.Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7F4K27KVTN2XTQHXVC80K78")
EVIDENCE=pathlib.Path("/home/runkai/.no-mistakes/evidence/01M7F4K27KVTN2XTQHXVC80K78")
base=os.environ.copy()
for key in list(base):
    if key.startswith("FM_") or key.startswith("TASKS_AXI_") or key == "TMUX": base.pop(key)
base.update(GIT_CONFIG_GLOBAL="/dev/null", GIT_CONFIG_NOSYSTEM="1")
log=[]; results=[]
def call(args, env=None, expected=0, record=False):
    p=subprocess.run([str(a) for a in args],cwd=ROOT,env=env or base,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=30)
    if record: log.append("$ " + " ".join(map(str,args)) + "\n" + p.stdout + "exit="+str(p.returncode))
    if expected is not None and p.returncode != expected: raise AssertionError(p.stdout)
    return p
with tempfile.TemporaryDirectory(prefix="fm-live-",dir=ROOT/".live-validation-tmp") as tmp:
  for actor,posture,case in [
      ("main","attended","green"),("main","away","green"),("branch","away","green"),
      ("branch","attended","green"),
      ("main","attended","off"),("main","away","off"),("branch","away","off"),
      ("main","attended","malformed"),("main","attended","missing-preference"),
      ("main","attended","restriction"),("branch","away","restriction"),
      ("main","attended","failed"),("main","attended","missing-ready"),
      ("main","attended","decision"),("main","attended","dirty"),
      ("main","attended","wrong-head"),("main","attended","dirty-default"),
      ("main","attended","diverged"),("main","attended","off-at-lock"),
      ("main","attended","baseline-off")]:
    name=f"{actor}-{posture}-{case}"
    log.append("\nSCENARIO " + name)
    lab=pathlib.Path(tmp)/name
    call([ROOT/"bin/fm-lab-home.sh","create",lab])
    env=base | {"FM_HOME":str(lab),"FM_SUPERVISION_ACTOR":actor}
    proj=lab/"projects/demo"; worker=lab/"worker"
    call(["git","init","-q","-b","main",proj])
    def git(*args,wd=proj): return call(["git","-C",wd,*args]).stdout.strip()
    def commit(msg,wd=proj): git("-c","user.name=Live Test","-c","user.email=live@example.invalid","-c","commit.gpgsign=false","commit","-qm",msg,"--allow-empty",wd=wd)
    commit("base")
    initial=git("rev-parse","HEAD")
    call(["git","clone","-q",proj,worker])
    git("checkout","-qb","fm/task-local",wd=worker)
    (worker/"change.txt").write_text("validated local change\n")
    git("add","change.txt",wd=worker); commit("ship",wd=worker)
    head=git("rev-parse","HEAD",wd=worker)
    git("fetch","-q",worker,"fm/task-local:fm/task-local")
    (lab/"state/task-local.meta").write_text(f"project={proj}\nworktree={worker}\nkind=ship\nmode=local-only\nyolo=off\nbranch=fm/task-local\n")
    (lab/"data/projects.md").write_text("- demo [local-only] - registry yolo off\n")
    (lab/".tasks.toml").write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    (lab/"state/task-local.status").write_text(f"done: validation passed at {head}\n")
    # Actual committed artifact check, rather than relying only on a done declaration.
    assert git("show",f"{head}:change.txt") == "validated local change"
    call([ROOT/"bin/fm-proactive.sh","on"],env,record=True)
    if posture=="away": call([ROOT/"bin/fm-afk-contract.sh","enter","--words","continue approved work"],env,record=True)
    if case in ("off","baseline-off"): call([ROOT/"bin/fm-proactive.sh","off"],env,record=True)
    if case=="malformed": (lab/"config/proactive").write_text("yes\n")
    if case=="missing-preference": (lab/"config/proactive").unlink()
    if case=="restriction": call([ROOT/"bin/fm-captain-hold.sh","hold","task-local","--title","Review first","--reason","explicit review-first instruction"],env,record=True)
    if case=="failed":
      with (lab/"state/task-local.status").open("a") as f: f.write("failed: validation failed\n")
    if case=="decision":
      with (lab/"state/task-local.status").open("a") as f: f.write("needs-decision: approval choice\n")
    if case=="missing-ready": (lab/"state/task-local.status").unlink()
    if case=="dirty": (worker/"uncommitted.txt").write_text("unique work")
    if case=="wrong-head": commit("extra unvalidated change",wd=worker)
    if case=="dirty-default": (proj/"uncommitted.txt").write_text("unique default work")
    if case=="diverged": commit("independent main change"); initial=git("rev-parse","HEAD")
    metadata=(lab/"state/task-local.meta").read_bytes()
    args=[str(ROOT/"bin/fm-merge-local.sh"),"task-local"]
    if case!="baseline-off": args.append("--proactive")
    if case=="off-at-lock":
      # Hold the product's real preference lock to force the merge's second read.
      lockargs=["bash","-c",'source "$1/bin/fm-wake-lib.sh"; fm_lock_acquire_wait "$FM_HOME/config/.proactive.lock"; echo LOCKED; read -r release; fm_lock_release "$FM_HOME/config/.proactive.lock"',"_",str(ROOT)]
      owner=subprocess.Popen(lockargs,cwd=ROOT,env=env,stdin=subprocess.PIPE,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
      assert owner.stdout.readline().strip()=="LOCKED"
      merging=subprocess.Popen(args,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True)
      try:
        # Wait until the merge is sleeping in the lock retry, after its first status read.
        time.sleep(0.8)
        assert merging.poll() is None, "merge bypassed held proactive lock"
        (lab/"config/proactive").write_text("off\n")
      finally:
        owner.communicate("release\n",timeout=10)
      out=merging.communicate(timeout=15)[0]
      p=subprocess.CompletedProcess(args,merging.returncode,out)
      log.append("$ " + " ".join(args) + " [mode changed to off while waiting for preference lock]\n" + out + f"exit={p.returncode}")
    else: p=call(args,env,expected=None,record=True)
    after=git("rev-parse","HEAD")
    should_land=case in ("green","baseline-off") and not(actor=="branch" and posture=="attended")
    assert (p.returncode==0)==should_land, name+" unexpected result: "+p.stdout
    assert after==(head if should_land else initial), name+" default branch moved incorrectly"
    assert metadata==(lab/"state/task-local.meta").read_bytes(), "dispatch metadata changed"
    if case=="restriction": assert "still held for the captain" in p.stdout
    if case=="off-at-lock": assert "off at action time" in p.stdout
    if should_land: assert (proj/"change.txt").read_text()=="validated local change\n"
    log.append(f"main_before={initial}\nship_head={head}\nmain_after={after}\ndispatch_metadata_unchanged=true\nobserved={'landed validated head' if should_land else 'refused without moving main'}")
    results.append(dict(name=name,result="pass",landed=should_land,returncode=p.returncode,before=initial,ship_head=head,after=after))
    if name=="main-attended-green":
      instructions=call([ROOT/"bin/fm-proactive.sh","instructions"],env,record=True).stdout
      assert "ordinary GitHub PR merges and local-only landings" in instructions
      (EVIDENCE/"proactive-instructions.txt").write_text(instructions)
      branch=call([ROOT/"bin/fm-branch-prompt.sh"],env).stdout
      assert "active proactive policy supplies standing approval" in branch
      (EVIDENCE/"branch-instructions.txt").write_text(branch)
  log.append("\nAll disposable homes and fixture repositories removed on driver exit.")
(EVIDENCE/"live-local-transcript.log").write_text("\n".join(log)+"\n")
(EVIDENCE/"live-local-results.json").write_text(json.dumps(results,indent=2)+"\n")
print(json.dumps(results,indent=2))
