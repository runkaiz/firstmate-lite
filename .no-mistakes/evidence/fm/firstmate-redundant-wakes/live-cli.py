from pathlib import Path
import os,subprocess,time,re,shutil,json,threading
ROOT=Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7RCW1DGVQEFV4XPMHQNTV34")
EVID=Path("/home/runkai/.no-mistakes/evidence/01M7RCW1DGVQEFV4XPMHQNTV34")
BASE=ROOT/".test-phase/live"
SOCKET=ROOT/".t"
ENV={k:v for k,v in os.environ.items() if not k.startswith(("FM_","TASKS_AXI_","GIT_")) and k not in ("TMUX","TMUX_PANE")}
ENV.update(GIT_CONFIG_GLOBAL="/dev/null",GIT_CONFIG_NOSYSTEM="1",GIT_AUTHOR_NAME="Lab",GIT_AUTHOR_EMAIL="lab@example.invalid",GIT_COMMITTER_NAME="Lab",GIT_COMMITTER_EMAIL="lab@example.invalid",TMPDIR=str(ROOT/".test-phase/tmp"))
log=(EVID/"live-cli-transcript.log").open("w")
results=[]

def run(args,env=None,check=True):
    e=ENV.copy();e.update(env or {})
    p=subprocess.run([str(x) for x in args],cwd=ROOT,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,timeout=25)
    log.write("$ "+" ".join(str(x) for x in args)+"\n"+p.stdout+p.stderr+f"[exit {p.returncode}]\n");log.flush()
    if check and p.returncode: raise RuntimeError(f"Command failed: {args}: {p.stderr}")
    return p

def cli(home,script,*args,extra=None):
    return run(["bash",ROOT/"bin"/script,*args],dict(FM_HOME=str(home),TMUX=TMUX,**(extra or {})))

def shell(home,program,*args):
    return run(["bash","-c",program,"_",str(ROOT),*args],dict(FM_HOME=str(home),TMUX=TMUX))

def new(name,verb="done"):
    h=BASE/name
    cli(h,"fm-lab-home.sh","create",str(h))
    (h/"config/supervision-host-off").touch()
    (h/"config/backlog-backend").write_text("manual\n")
    p=h/"projects/repo"
    run(["git","init","-q","-b","main",p]);run(["git","-C",p,"commit","-q","--allow-empty","-m","base"])
    (h/"state/child.meta").write_text(f"window=fm-lab-validation:0\nbackend=tmux\nharness=claude\nkind=ship\nmode=local-only\nyolo=off\nspawn_gen=lab-{name}\nproject={p}\nworktree={p}\nbranch=fix/child\n")
    (h/"state/child.status").write_text(f"{verb}: waiting for merge approval\n")
    cli(h,"fm-busy-event.sh","arm",str(h/"state"),"child","--state","idle","--source","fm-recovery","--event","lab-disposable-record")
    return h

def age(h):
    for p in (h/"state").glob("child.*"):
        if p.is_file(): os.utime(p,(time.time()-180,time.time()-180))

def scan(h):
    age(h)
    cli(h,"fm-crew-state.sh","child",extra={"FM_CREW_STATE_NO_FORGE":"1"})
    cli(h,"fm-inactive-reconcile.sh","scan","--startup",extra={"FM_INACTIVE_RECONCILE_SECS":"60"})
    return queue(h)

def queue(h):
    p=h/"state/.wake-queue"
    v=p.read_text() if p.exists() else ""
    log.write("PERSISTED .wake-queue:\n"+v+"[end queue]\n");log.flush()
    return v

def receipts(h):
    rows=[]
    for p in (h/"state/terminal-outcomes").glob("*.presented"):
        rows.append(p.read_text())
    log.write("PERSISTED terminal presentation receipts:\n"+"\n".join(rows)+"\n[end receipts]\n");log.flush()
    return rows

def wake(h,key="child.status",kind="signal"):
    shell(h,". \"$1/bin/fm-wake-lib.sh\"; fm_wake_append \"$2\" \"$3\" \"lab observation\"",kind,key)

def present(h,extra=None):
    p=cli(h,"fm-wake-drain.sh",extra=extra)
    m=re.search(r"WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)",p.stderr)
    assert m,(p.stdout,p.stderr)
    return m.group(1),m.group(2),p.stdout

def ack(h,binding,extra=None):
    cli(h,"fm-wake-drain.sh","--ack-through",binding[0],"--recovery-generation",binding[1],extra=extra)

def recovery(h):
    (h/"state/.wake-queue").write_text("")
    shell(h,". \"$1/bin/fm-wake-lib.sh\"; fm_recovery_marker_publish \"$FM_HOME/state/.watcher-down\" handling")

def scenario(name,fn):
    log.write("\n=== "+name+" ===\n");log.flush()
    try:
        fn();results.append(dict(name=name,result="pass",live=True))
        print("PASS "+name,flush=True)
    except Exception as exc:
        results.append(dict(name=name,result="fail",live=True,error=str(exc)))
        print("FAIL "+name+": "+str(exc),flush=True)

try:
    BASE.mkdir(parents=True,exist_ok=True)
    run(["tmux","-f","/dev/null","-S",SOCKET,"new-session","-d","-s","fm-lab-validation","-x","120","-y","35","-c",ROOT,"bash --noprofile --norc"])
    TMUX=run(["tmux","-S",SOCKET,"display-message","-p","-t","fm-lab-validation","#{socket_path},#{pid},0"]).stdout.strip()
    def handled():
        for actor in ("main","branch"):
          for verb in ("done","failed"):
            h=new("handled-"+actor+"-"+verb,verb)
            assert "inactive-outcome:" in scan(h),"baseline inactive scan failed to surface the real task state"
            # Acknowledge the actual fallback and status together via the ordinary drain.
            wake(h)
            e={"FM_SUPERVISION_ACTOR":actor}
            if actor=="branch":
                cli(h,"fm-wake-grant.sh","activate",str(os.getpid()),"lab")
                seqs=[r.split("\t")[1] for r in queue(h).splitlines()]
                cli(h,"fm-wake-grant.sh","publish","lab",*seqs)
            b=present(h,e);assert f"{verb}: waiting for merge approval" in b[2]
            assert not receipts(h),"presentation acknowledged before handling"
            ack(h,b,e);assert len(receipts(h))==1
            assert "inactive-outcome:" not in scan(h)
            assert (h/"state/child.meta").exists()
    scenario("Ordinary main and branch terminal acknowledgement stays quiet on subsequent real scans",handled)

    def stale():
      for mutation in ("append","replace","unseen"):
        h=new("stale-"+mutation);wake(h)
        b=present(h)
        if mutation=="append":
            with (h/"state/child.status").open("a") as f:f.write("failed: new validation failure\n")
        elif mutation=="replace":
            (h/"state/child.status").rename(h/"state/old-status")
            (h/"state/child.status").write_text("done: waiting for merge approval\n")
        else:
            # A new, never-presented sibling uses the same real endpoint and project.
            (h/"state/other.meta").write_text((h/"state/child.meta").read_text().replace("spawn_gen=lab-","spawn_gen=other-"))
            (h/"state/other.status").write_text("failed: never presented sibling\n")
            cli(h,"fm-busy-event.sh","arm",str(h/"state"),"other","--state","idle","--source","fm-recovery","--event","lab-disposable-record")
            for p in (h/"state").glob("other.*"):os.utime(p,(time.time()-180,time.time()-180))
        ack(h,b)
        if mutation!="unseen": assert not receipts(h)
        assert "inactive-outcome:" in scan(h)
    scenario("Acknowledging an old status preserves appended, replaced, and never-presented outcomes",stale)

    def branch():
      h=new("branch-processed")
      seq=cli(h,"fm-branch-outcome.sh","append","--task","child","--verdict","captain","--summary","Ready for approval").stdout.strip()
      cli(h,"fm-branch-outcome.sh","mark-read","--through",seq)
      assert "inactive-outcome:" in scan(h),"merely reading suppressed notification"
      cli(h,"fm-branch-outcome.sh","mark-processed","--through",seq)
      assert len(receipts(h))==1
      assert "inactive-outcome:" not in scan(h)
      with (h/"state/child.status").open("a") as f:f.write("failed: a new failure after handled success\n")
      assert "inactive-outcome:" in scan(h)
    scenario("Processing a branch outcome suppresses its duplicate while a later failure still notifies",branch)

    def empty():
      for verb in ("done","failed"):
        h=new("empty-"+verb,verb);recovery(h);b=present(h)
        assert b[0]=="0" and f"{verb}: waiting for merge approval" in b[2]
        ack(h,("0","wrong-generation"));assert not receipts(h)
        ack(h,b);assert len(receipts(h))==1
        assert "inactive-outcome:" not in scan(h)
      h=new("empty-new-generation");recovery(h);b=present(h);recovery(h);ack(h,b)
      assert not receipts(h)
      assert "inactive-outcome:" in scan(h)
    scenario("Empty-queue recovery acknowledges only its presented generation",empty)

    def landing():
      h=new("local-landing");p=h/"projects/repo"
      run(["git","-C",p,"checkout","-q","-b","fix/child"])
      run(["git","-C",p,"commit","-q","--allow-empty","-m","ship change"])
      head=run(["git","-C",p,"rev-parse","HEAD"]).stdout
      run(["git","-C",p,"checkout","-q","main"])
      assert "inactive-outcome:" in scan(h)
      cli(h,"fm-merge-local.sh","child")
      assert run(["git","-C",p,"rev-parse","HEAD"]).stdout==head
      assert len(receipts(h))==1
      assert "inactive-outcome:" not in scan(h)
    scenario("Synchronous local landing records its presentation and removes the matching fallback",landing)

finally:
    try:run(["tmux","-S",SOCKET,"kill-server"],check=False)
    finally:
        if SOCKET.exists():SOCKET.unlink()
        if BASE.exists():shutil.rmtree(BASE)
        (EVID/"live-cli-results.json").write_text(json.dumps(results,indent=2)+"\n")
        log.write("Disposable homes and private tmux server removed.\n");log.close()
if any(r["result"]!="pass" for r in results):raise SystemExit(1)
