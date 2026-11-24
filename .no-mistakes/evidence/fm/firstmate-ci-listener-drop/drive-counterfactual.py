import os
from pathlib import Path
import shutil
import subprocess
import tempfile

root = Path.cwd()
evidence = Path(__file__).parent
lab = Path(tempfile.mkdtemp(prefix="counterfactual-", dir=root / ".validation-ci-tmp"))
state = lab / "home/state"
state.mkdir(parents=True)
claims = lab / "claims"
claims.mkdir()
env = {k: v for k, v in os.environ.items() if not k.startswith("FM_")}
env.update(FM_HOME=str(lab / "home"), FM_ROOT_OVERRIDE=str(root),
           FM_STATE_OVERRIDE=str(state), FM_PROCEVENT_CLAIM_ROOT=str(claims),
           TMPDIR=str(lab), FM_GUARD_READ_ONLY="1")
log = (evidence / "before-after-and-drain.txt").open("w")

def note(text):
    print(text, flush=True)
    print(text, file=log, flush=True)

def run(command):
    result = subprocess.run(list(map(str, command)), env=env, text=True,
                            stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=20)
    note("$ " + " ".join(map(str, command)))
    note(result.stdout.strip() or "(no stdout)")
    if result.stderr:
        note("stderr: " + result.stderr.strip())
    assert result.returncode == 0, result.returncode
    return result.stdout

try:
    baseline_bin = lab / "before/bin"
    baseline_bin.mkdir(parents=True)
    for item in (root / "bin").iterdir():
        if item.name != "fm-procevent.sh":
            (baseline_bin / item.name).symlink_to(item)
    baseline = baseline_bin / "fm-procevent.sh"
    content = subprocess.run(["git", "show", "220db688bdded7976780f853ae8d41e77e733bca:bin/fm-procevent.sh"],
                             check=True, stdout=subprocess.PIPE).stdout
    baseline.write_bytes(content)
    baseline.chmod(0o700)
    current = root / "bin/fm-procevent.sh"
    source = "ci-counterfactual"
    run([current, "register", "ci", source, "--", "/bin/sleep", "300"])
    claim = claims / (source + ".claim")
    claim.write_text("incomplete claim\n")
    queue = state / ".wake-queue"
    note("Same persisted CI registration and damaged claim for both executable versions.")
    before = run([baseline, "reconcile"])
    assert "uncertain=1" in before and not queue.exists()
    note("Observed at base: uncertain listener counted, no durable warning delivered.")
    after = run([current, "reconcile"])
    assert "uncertain=1" in after and queue.is_file()
    assert "cannot verify its listener" in queue.read_text()
    assert claim.read_text() == "incomplete claim\n"
    note("Observed at target: durable warning delivered; damaged ownership left untouched.")
    note("\nReal notification presentation (no primary or supervision process started in disposable home):")
    presented = run([root / "bin/fm-wake-drain.sh"])
    assert "cannot verify its listener" in presented and source in presented
    note("Verified: ordinary drain presents the missing-listener warning and recovery guidance.")
finally:
    shutil.rmtree(lab)
    note("Disposable comparison home removed; no listener was started.")
    log.close()
