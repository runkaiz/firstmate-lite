from pathlib import Path
import os,subprocess,time,re,shutil,json,threading
ROOT=Path("/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7RCW1DGVQEFV4XPMHQNTV34")
EVID=Path("/home/runkai/.no-mistakes/evidence/01M7RCW1DGVQEFV4XPMHQNTV34")
BASE=ROOT/".test-phase/live"
SOCKET=ROOT/".t"
ENV={k:v for k,v in os.environ.items() if not k.startswith(("FM_","TASKS_AXI_","GIT_")) and k not in ("TMUX","TMUX_PANE")}
ENV.update(GIT_CONFIG_GLOBAL="/dev/null",GIT_CONFIG_NOSYSTEM="1",GIT_AUTHOR_NAME="Lab",GIT_AUTHOR_EMAIL="lab@example.invalid",GIT_COMMITTER_NAME="Lab",GIT_COMMITTER_EMAIL="lab@example.invalid",TMPDIR=str(ROOT/".test-phase/tmp"))
log=(EVID/"recheck-live-interleaving-transcript.log").open("w")
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

def wait_path(path):
    deadline=time.monotonic()+8
    while not path.exists():
        if time.monotonic()>deadline:raise RuntimeError("Timed out waiting for "+str(path))
        time.sleep(.05)

try:
    BASE.mkdir(parents=True,exist_ok=True)
    run(["tmux","-f","/dev/null","-S",SOCKET,"new-session","-d","-s","fm-lab-validation","-x","120","-y","35","-c",ROOT,"bash --noprofile --norc"])
    TMUX=run(["tmux","-S",SOCKET,"display-message","-p","-t","fm-lab-validation","#{socket_path},#{pid},0"]).stdout.strip()
    def concurrent():
      for mode in ("retire","replace-snapshot"):
        h=new("concurrent-"+mode);wake(h);b=present(h)
        env=ENV.copy();env.update(FM_HOME=str(h),TMUX=TMUX)
        holder_program="""
. "$1/bin/fm-wake-lib.sh"
. "$1/bin/fm-classify-lib.sh"
lock=$(fm_meta_lock_path "$FM_HOME/state/child.meta") || exit 1
fm_lock_acquire_wait "$lock" || exit 1
trap 'fm_lock_release "$lock"' EXIT
touch "$FM_HOME/state/meta-held"
for i in {1..160}; do
  [ ! -e "$FM_HOME/state/release-meta" ] || break
  sleep 0.05
done
[ -e "$FM_HOME/state/release-meta" ] || exit 1
if [ "$2" = retire ]; then status_retire_presentation_task "$FM_HOME/state" child || exit 1; fi
"""
        holder=subprocess.Popen(["bash","-c",holder_program,"_",str(ROOT),mode],cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
        ackproc=None
        try:
          wait_path(h/"state/meta-held")
          args=["bash",str(ROOT/"bin/fm-wake-drain.sh"),"--ack-through",b[0],"--recovery-generation",b[1]]
          log.write("$ concurrent "+" ".join(args)+"; metadata lock held by bounded holder\n");log.flush()
          ackproc=subprocess.Popen(args,cwd=ROOT,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True)
          wait_path(h/"state/.inactive-outcome-reconcile.lock/pid")
          assert not (h/"state/.status-presentation-lock").exists(),"ack kept presentation locked while waiting on metadata"
          if mode=="replace-snapshot":
            with (h/"state/child.status").open("a") as f:f.write("failed: new outcome while old acknowledgement waits\n")
            newer=present(h)
            assert "failed: new outcome while old acknowledgement waits" in newer[2]
          (h/"state/release-meta").touch()
          hout,herr=holder.communicate(timeout=12)
          aout,aerr=ackproc.communicate(timeout=12)
          log.write("cleanup-holder:\n"+hout+herr+f"[exit {holder.returncode}]\nacknowledgement:\n"+aout+aerr+f"[exit {ackproc.returncode}]\n");log.flush()
          assert holder.returncode==0 and ackproc.returncode==0,"bounded interleaving did not complete"
          if mode=="retire":
            assert not (h/"state/child.status").exists()
          else:
            assert not receipts(h),"old ack hid the newer failure"
            snapshot=(h/"state/.main.status-wake-presented").read_text()
            log.write("PERSISTED concurrent replacement snapshot:\n"+snapshot)
            assert str((h/"state/child.status").stat().st_size) in snapshot
            assert "inactive-outcome:" in scan(h)
        finally:
          for proc in (holder,ackproc):
            if proc and proc.poll() is None:proc.kill();proc.communicate()
    scenario("Acknowledgement releases presentation before metadata waits and preserves a concurrent new snapshot",concurrent)
finally:
    try:run(["tmux","-S",SOCKET,"kill-server"],check=False)
    finally:
        if SOCKET.exists():SOCKET.unlink()
        if BASE.exists():shutil.rmtree(BASE)
        (EVID/"recheck-live-interleaving-results.json").write_text(json.dumps(results,indent=2)+"\n")
        log.write("Disposable homes and private tmux server removed.\n");log.close()
if any(r["result"]!="pass" for r in results):raise SystemExit(1)
