import os
import pathlib
import shutil
import signal
import subprocess
import tempfile
import time

ROOT = pathlib.Path.cwd()
EVIDENCE = pathlib.Path(__file__).parent
LAB = pathlib.Path(tempfile.mkdtemp(prefix="live-monitor-", dir=ROOT / ".validation-ci-tmp"))
STATE = LAB / "home/state"
STATE.mkdir(parents=True)
CLAIMS = LAB / "claims"
env = os.environ.copy()
for key in list(env):
    if key.startswith("FM_") or key in ("TASKS_AXI_FILE", "TASKS_AXI_BACKEND"):
        del env[key]
env.update(FM_HOME=str(LAB / "home"), FM_STATE_OVERRIDE=str(STATE),
           FM_ROOT_OVERRIDE=str(ROOT), FM_PROCEVENT_CLAIM_ROOT=str(CLAIMS),
           TMPDIR=str(LAB), FM_PROCEVENT_OWNER_CHECK_SECONDS="1")
PRODUCT = ROOT / "bin/fm-procevent.sh"
SOURCE = "ci-live-monitor"
claim = CLAIMS / (SOURCE + ".claim")
runner_file = STATE / "procevent" / (SOURCE + ".runner")
queue = STATE / ".wake-queue"
saved = None
groups = set()
log = (EVIDENCE / "live-monitor-transcript.txt").open("w")

def note(text):
    print(text, flush=True)
    print(text, file=log, flush=True)

def run(*args, product=PRODUCT):
    result = subprocess.run([str(product), *args], env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    note("$ " + str(product.relative_to(ROOT)) + " " + " ".join(args))
    note(result.stdout.strip() or "(no stdout)")
    if result.stderr:
        note("stderr: " + result.stderr.strip())
    assert result.returncode == 0, result.returncode
    return result.stdout

def require(condition, message):
    if not condition:
        raise AssertionError(message)
    note("Verified: " + message)

def wait_for(predicate, message):
    deadline = time.monotonic() + 12
    while time.monotonic() < deadline:
        if predicate():
            return
        time.sleep(.05)
    raise AssertionError(message)

def rows():
    return queue.read_text().splitlines() if queue.is_file() else []

def starts():
    return (LAB / "started").read_text().splitlines() if (LAB / "started").exists() else []

def snapshot(name):
    dest = EVIDENCE / name
    dest.write_text(queue.read_text())
    note("Durable notification queue:\n" + dest.read_text().strip())

def group_alive(pid):
    try:
        os.killpg(pid, 0)
        return True
    except ProcessLookupError:
        return False

def kill_group(pid):
    require(os.getpgid(pid) == pid, "runner leads its isolated process group " + str(pid))
    os.killpg(pid, signal.SIGKILL)
    wait_for(lambda: not group_alive(pid), "runner process group did not disappear")

try:
    note("Real product: fm-procevent.sh at target commit; no CLI stubs or production services.")
    note("External input: disposable shell source blocks until a local release file appears.")
    note("This exercises monitor lifecycle, not a real forge build or no-mistakes pipeline.")
    child = LAB / "blocking-source.sh"
    child.write_text('#!/usr/bin/env bash\nset -eu\nprintf "%s\\n" "$$" >> "$1/started"\nwhile [ ! -f "$1/release" ]; do sleep .1; done\nprintf "ci_wait: action\\nevidence: disposable external source completed\\n"\n')
    child.chmod(0o700)
    argv = [str(child), str(LAB)]
    run("register", "ci", SOURCE, "--", *argv)
    run("ensure-listening", SOURCE)
    wait_for(lambda: len(starts()) == 1, "external source did not start")
    pid = int(runner_file.read_text())
    groups.add(pid)
    saved = claim.read_bytes()
    require("live" in run("list"), "confirmed listener is live")
    run("reconcile")
    require(not rows(), "healthy pending listener produces no warning")

    note("\nSCENARIO: ambiguous live ownership warns without replacement or signals")
    claim.write_text("incomplete claim\n")
    damaged = claim.read_bytes()
    run("list")
    out = run("reconcile")
    require("started=0 stopped=0 uncertain=1" in out, "uncertain ownership neither restarts nor stops a listener")
    require(len(rows()) == 1 and "cannot verify its listener" in rows()[0], "one actionable stranded notification reaches the durable queue")
    require(claim.read_bytes() == damaged, "uncertain claim bytes are preserved")
    require(group_alive(pid) and len(starts()) == 1, "original live poller survives and no duplicate poller starts")
    for _ in range(3):
        run("reconcile")
    require(len(rows()) == 1, "repeated cycles produce no duplicate warning for this registration")
    snapshot("live-uncertain-queue.tsv")

    note("\nSCENARIO: a fresh registration can warn again; queue failure remains retryable")
    run("register", "ci", SOURCE, "--", *argv)
    queue.rename(LAB / "first-queue")
    queue.mkdir()
    run("reconcile")
    require(queue.is_dir(), "notification append failure was injected through a real filesystem obstruction")
    queue.rmdir()
    (LAB / "first-queue").rename(queue)
    run("reconcile")
    require(len(rows()) == 2, "notification retries successfully after queue obstruction clears")
    keys = [row.split("\t")[3] for row in rows()]
    require(len(set(keys)) == 2, "fresh registration has a distinct durable notification identity")
    run("reconcile")
    require(len(rows()) == 2 and len(starts()) == 1, "new registration also deduplicates and preserves the existing poller")
    snapshot("live-new-registration-queue.tsv")

    note("\nSCENARIO: dropped listener recovers only after ownership is provably dead")
    kill_group(pid)
    out = run("reconcile")
    require("started=0 stopped=0 uncertain=1" in out and len(starts()) == 1,
            "dead listener with unreadable claim still preserves ownership")
    claim.write_bytes(saved)
    saved = None
    out = run("reconcile")
    require("started=1" in out, "restoring verifiable dead ownership restarts the listener")
    wait_for(lambda: len(starts()) == 2, "replacement source did not start")
    replacement = int(runner_file.read_text())
    groups.add(replacement)
    require(replacement != pid and "live" in run("list"), "one replacement listener is confirmed live")
    (LAB / "release").touch()
    inbox = STATE / "procevent-inbox"
    wait_for(lambda: inbox.exists() and len(list(inbox.glob(SOURCE + ".*.result"))) == 1
             and len(rows()) == 3 and not (STATE / "procevent" / (SOURCE + ".source")).exists(),
             "completion did not capture, notify and retire")
    result = next(inbox.glob(SOURCE + ".*.result"))
    note("Captured external completion:\n" + result.read_text().strip())
    require(run("classify", str(result)).strip() == "action", "real adapter classifies the captured completion")
    shutil.copyfile(result, EVIDENCE / "live-captured-completion.result")
    seq = result.name[len(SOURCE) + 1:-len(".result")]
    run("handled", SOURCE, seq)
    run("reconcile")
    run("reconcile")
    require(len(rows()) == 3 and len(starts()) == 2, "handled terminal result never replays or starts another listener")
    run("list")
    snapshot("live-recovered-queue.tsv")
    note("\nAll live monitor scenarios passed.")
finally:
    if saved is not None and claim.exists():
        claim.write_bytes(saved)
    try:
        run("retire", SOURCE)
    finally:
        for pid in groups:
            if group_alive(pid):
                try:
                    os.killpg(pid, signal.SIGKILL)
                except ProcessLookupError:
                    pass
        shutil.rmtree(LAB)
        note("Disposable monitor home and external source removed.")
        log.close()
