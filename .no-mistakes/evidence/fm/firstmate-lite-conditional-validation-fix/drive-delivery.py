"""Run from the gate worktree. Exercise production CLIs using disposable data."""
import json
import os
from pathlib import Path
import re
import shutil
import subprocess
import tempfile
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
import urllib.request
import yaml

root = Path.cwd()
scratch = Path(tempfile.mkdtemp(prefix="delivery-", dir=root / "test-phase-scratch"))
env = os.environ.copy()
for key in list(env):
    if key.startswith("FM_") or key in ("TASKS_AXI_FILE", "TASKS_AXI_BACKEND"):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL=os.devnull, GIT_CONFIG_SYSTEM=os.devnull,
           GIT_CONFIG_NOSYSTEM="1", GIT_TERMINAL_PROMPT="0", TMPDIR=str(scratch))
home = scratch / "home"
env["FM_HOME"] = str(home)
consumer = root / "bin/fm-delivery-record.py"
transcript = []

def note(text):
    transcript.append(str(text).replace(str(root), "<WORKTREE>").replace(str(scratch), "<SCRATCH>"))

def run(*args, cwd=root, extra=None):
    return subprocess.run([str(a) for a in args], cwd=cwd, env=env | (extra or {}),
                          capture_output=True, text=True, timeout=30)

def ok(*args, **kwargs):
    p = run(*args, **kwargs)
    assert p.returncode == 0, (args, p.stdout, p.stderr)
    return p.stdout

server = None
try:
    ok("bash", root / "bin/fm-lab-home.sh", "create", home)
    repo = scratch / "repository"
    ok("git", "init", "-q", repo)
    def commit(message):
        ok("git", "-C", repo, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
           "-c", "commit.gpgsign=false", "commit", "--allow-empty", "-m", message)
        return ok("git", "-C", repo, "rev-parse", "HEAD").strip()
    head = commit("Synthetic internal change")
    ok("bash", root / "bin/fm-brief.sh", "internal", "synthetic", "--mode", "direct-PR", "--delivery-surface", "internal-only")
    brief = (home / "data/internal/brief.md").read_text()
    command = re.search(r"append the output of `([^`]+)`", brief).group(1)
    record = ok("bash", "-c", command, cwd=repo).strip()
    note("INTAKE: fm-brief.sh internal synthetic --mode direct-PR --delivery-surface internal-only")
    note("Generated producer command: " + command)
    note("Actual PR-body output: " + record)

    ok("bash", root / "bin/fm-brief.sh", "promoted", "synthetic", "--scout")
    scout = home / "data/promoted/brief.md"
    scout.write_text(scout.read_text().replace("{TASK}", "Update internal maintainer documentation.").replace("{FIRSTMATE_SPEC}", "Preserve all product behavior."))
    (home / "state/promoted.meta").write_text("kind=scout\nwindow=fm-promoted\nworktree=" + str(repo) + "\n")
    promoted = ok("bash", root / "bin/fm-promote.sh", "promoted", "--mode", "direct-PR", "--delivery-surface", "internal-only", "--yolo", "off")
    instructions = (home / "data/promoted/ship-instructions.md").read_text()
    promoted_command = re.search(r"append the output of `([^`]+)`", instructions).group(1)
    assert ok("bash", "-c", promoted_command, cwd=repo).strip() == record
    note("PROMOTION: " + promoted.splitlines()[0])
    note("Persisted task state: " + (home / "state/promoted.meta").read_text())
    note("Promoted producer output equals ordinary intake producer output.")
    for surface in ("product-facing", "mixed", "unknown"):
        ok("bash", root / "bin/fm-brief.sh", surface, "synthetic", "--mode", "no-mistakes", "--delivery-surface", surface)
        emitted = (home / f"data/{surface}/brief.md").read_text()
        assert "Delivery contract: mode=no-mistakes" in emitted
        assert "fm-delivery-record.py emit" not in emitted
        note(f"INTAKE {surface}: " + next(l for l in emitted.splitlines() if l.startswith("Delivery contract:")))
    rejected = run("bash", root / "bin/fm-brief.sh", "invalid", "synthetic", "--mode", "direct-PR", "--delivery-surface", "not-a-surface")
    assert rejected.returncode != 0 and not (home / "data/invalid/brief.md").exists()
    note("INVALID INTAKE: " + rejected.stderr.strip())

    workflow = yaml.safe_load((root / ".github/workflows/no-mistakes-required.yml").read_text())
    steps = workflow["jobs"]["check"]["steps"]
    assert steps[0]["with"]["ref"] == "${{ github.event.pull_request.base.sha }}"
    assert steps[0]["with"]["persist-credentials"] is False
    policy = next(s for s in steps if s.get("id") == "delivery")
    fallback = steps[-1]
    assert fallback["if"] == "steps.delivery.outputs.direct != 'true'"
    assert "with" not in fallback
    pin = fallback["uses"].split("@")[1]
    verifier = scratch / "verify.py"
    with urllib.request.urlopen(f"https://raw.githubusercontent.com/kunchenguid/no-mistakes/{pin}/.github/actions/require-no-mistakes/verify.py", timeout=30) as response:
        verifier.write_bytes(response.read())
    state = {"status": 200, "body": record, "head": head, "actor": "contributor"}
    class Api(BaseHTTPRequestHandler):
        def do_GET(self):
            assert self.path == "/repos/synthetic/project/pulls/1"
            assert self.headers["Authorization"] == "Bearer synthetic-token"
            self.send_response(state["status"])
            self.end_headers()
            body = dict(number=1, body=state["body"], head=dict(sha=state["head"]), user=dict(login=state["actor"]))
            self.wfile.write(json.dumps(body).encode())
        def log_message(self, *args):
            pass
    server = HTTPServer(("127.0.0.1", 0), Api)
    thread = threading.Thread(target=server.serve_forever, daemon=True)
    thread.start()
    event = scratch / "event.json"
    event.write_text(json.dumps(dict(pull_request=dict(number=1, body="Stale event without declaration", head=dict(sha="0" * 40)))))
    output = scratch / "github-output"
    api_env = dict(GITHUB_API_URL=f"http://127.0.0.1:{server.server_port}", GITHUB_REPOSITORY="synthetic/project",
                   GITHUB_TOKEN="synthetic-token", GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output))
    note("CONSUMER: executing workflow delivery shell against real production check-live CLI; API data is synthetic localhost, not hosted GitHub.")
    def check(label, expected, **updates):
        state.update(updates)
        output.write_text("")
        p = run("bash", "-e", "-c", policy["run"], extra=api_env)
        note(f"{label}: exit={p.returncode}; stdout={p.stdout.strip()}; workflow output={output.read_text().strip()}; stderr={p.stderr.strip()}")
        if expected is None:
            assert p.returncode != 0 and not output.read_text()
        else:
            assert p.returncode == 0 and json.loads(p.stdout) == dict(direct=expected, requires_no_mistakes=not expected)
            assert output.read_text() == f"direct={str(expected).lower()}\n"
            if not expected:
                full = run("python3", verifier, extra=dict(PR_BODY=state["body"] or "", PR_HEAD_SHA=state["head"], PR_AUTHOR=state["actor"],
                           PR_NUMBER="1", NM_EXEMPT_AUTHORS="", NM_EXEMPT_BOT_AUTHORS="false", NM_EXEMPT_HEAD_BRANCHES=""))
                assert full.returncode != 0
                note(f"  Pinned full verifier: exit={full.returncode}; {full.stderr.strip()}")
    check("Current internal declaration overrides stale event", True)
    before = run("python3", verifier, extra=dict(PR_BODY=record, PR_HEAD_SHA=head, PR_AUTHOR="contributor",
                 PR_NUMBER="1", NM_EXEMPT_AUTHORS="", NM_EXEMPT_BOT_AUTHORS="false", NM_EXEMPT_HEAD_BRANCHES=""))
    assert before.returncode != 0
    note("BEFORE conditional routing: pinned verifier alone rejects the same valid internal declaration: " + before.stderr.strip())
    event.write_text(json.dumps(dict(pull_request=dict(number=1, body=record, head=dict(sha=head)))))
    note("Remaining checks keep a cached event with a valid old declaration; current API facts must still control the result.")
    for surface in ("product-facing", "mixed", "unknown", "untrusted"):
        check(f"Non-internal surface {surface}", False, body=record.replace('"surface":"internal-only"', f'"surface":"{surface}"'))
    variants = {
        "Missing record": "No declaration", "Removed record after reclassification": "",
        "Malformed JSON": "<!-- firstmate-delivery:v1 {broken} -->", "Duplicate records": record + record,
        "Wrong version": record.replace("v1 ", "v2 "), "Wrong policy": record.replace("no-mistakes-prod-only", "unknown-policy"),
        "Wrong mode": record.replace("direct-PR", "no-mistakes"),
        "Duplicate surface key": record.replace('"surface":"internal-only"', '"surface":"internal-only","surface":"mixed"'),
        "Unknown field": record.replace('"mode":"direct-PR"', '"mode":"direct-PR","extra":true'),
        "Missing head": re.sub(r',"head_sha":"[a-f0-9]+"', '', record),
    }
    for label, body in variants.items():
        check(label, False, body=body)
    newhead = commit("Synthetic next revision")
    check("Old declaration after new commit", False, body=record, head=newhead)
    refreshed = ok("bash", "-c", command, cwd=repo).strip()
    check("Regenerated declaration after new commit", True, body=refreshed)
    for actor in ("contributor", "kunchenguid", "github-actions[bot]", "dependabot[bot]"):
        check(f"Valid declaration for {actor}", True, actor=actor)
        check(f"Missing declaration for {actor}", False, body="No declaration")
        state["body"] = refreshed
    for status in (403, 500):
        check(f"API HTTP {status}", None, status=status)
    check("Malformed current head", None, status=200, head="short")
    emptybase = scratch / "pre-rollout-base"
    emptybase.mkdir()
    output.write_text("")
    p = run("bash", "-e", "-c", policy["run"], cwd=emptybase, extra=api_env)
    assert p.returncode == 0 and output.read_text() == "direct=false\n"
    note("BASE ROLLOUT: no consumer present -> " + output.read_text().strip() + "; pinned verifier remains selected.")
    note("Workflow semantics: base SHA checkout; credentials not persisted; fallback has no author/bot exemptions.")
    note("All product CLI assertions passed. No hosted GitHub job or model session was run.")
finally:
    if server:
        server.shutdown()
        server.server_close()
        thread.join()
    shutil.rmtree(scratch)
    evidence = Path(__file__).parent / "delivery-cli-transcript.txt"
    evidence.write_text("\n".join(transcript) + "\n")
    print(evidence)
