#!/usr/bin/env bash
# Regression tests for the pinned shared no-mistakes gate action.
set -u

# shellcheck source=tests/lib.sh disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ACTION_REF=f6441c96c352a18b9cadcaef6b6c7017e9ac3970
TMP_ROOT=$(fm_test_tmproot fm-no-mistakes-required)
VERIFY="$TMP_ROOT/verify.py"
OLD_SHA=1111111111111111111111111111111111111111
NEW_SHA=2222222222222222222222222222222222222222
SIGNATURE='Updates from [git push no-mistakes](https://github.com/kunchenguid/no-mistakes)'
COMPLETED_STEPS='[{"step":"review","status":"completed"},{"step":"test","status":"completed"},{"step":"document","status":"completed"}]'

fetch_shared_verifier() {
  command -v curl >/dev/null 2>&1 || fail "curl is required to exercise the pinned shared action"
  command -v python3 >/dev/null 2>&1 || fail "python3 is required to exercise the pinned shared action"
  curl --fail --silent --show-error --location \
    "https://raw.githubusercontent.com/kunchenguid/no-mistakes/${ACTION_REF}/.github/actions/require-no-mistakes/verify.py" \
    > "$VERIFY" || fail "could not fetch the pinned shared action verifier"
  [ -s "$VERIFY" ] || fail "the pinned shared action verifier was empty"
}

run_verifier() {
  local body=$1 head=$2
  NM_EXEMPT_AUTHORS='' NM_EXEMPT_BOT_AUTHORS=false NM_EXEMPT_HEAD_BRANCHES='' \
    PR_BODY="$body" PR_HEAD_SHA="$head" PR_AUTHOR=regression PR_NUMBER=3006 \
    python3 "$VERIFY" 2>&1
}

test_matching_head_and_completed_steps_pass() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$NEW_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  expect_code 0 "$rc" "shared action rejected an attestation bound to the current PR head"
  assert_contains "$output" "Found structurally compliant pipeline step attestation." \
    "shared action did not report the matching attestation as compliant"
  pass "shared action accepts a matching head_sha with completed required steps"
}

test_mismatched_head_fails_with_both_shas() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"head_sha\":\"$OLD_SHA\",\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation from a different PR head"
  assert_contains "$output" "$OLD_SHA" \
    "mismatched-head failure did not name the attestation head SHA"
  assert_contains "$output" "$NEW_SHA" \
    "mismatched-head failure did not name the actual PR head SHA"
  pass "shared action rejects a mismatched head_sha and names both SHAs"
}

test_missing_head_fails() {
  local body output rc
  body="$SIGNATURE
<!-- no-mistakes-pipeline-attestation:v1 {\"steps\":$COMPLETED_STEPS} -->"
  rc=0
  output=$(run_verifier "$body" "$NEW_SHA") || rc=$?
  [ "$rc" -ne 0 ] || fail "shared action accepted an attestation without head_sha"
  assert_contains "$output" "structured pipeline step attestation" \
    "missing-head failure did not explain that the attestation is invalid"
  pass "shared action rejects an attestation with no head_sha"
}

fetch_shared_verifier
test_matching_head_and_completed_steps_pass
test_mismatched_head_fails_with_both_shas
test_missing_head_fails

# Exercise the actual producer, normalized consumer, live GitHub adapter, and
# pinned fallback verifier. No invented pipeline attestation stands in for a
# successful conditional path.
python3 - "$ROOT" "$TMP_ROOT" "$VERIFY" <<'PYTEST' || fail "conditional delivery consumer regression failed"
import json
import os
import re
import runpy
import subprocess
import sys
import threading
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

root, scratch, verifier = map(Path, sys.argv[1:])
consumer = root / "bin/fm-delivery-record.py"
sha = "2" * 40
other = "1" * 40
internal_direct = runpy.run_path(str(consumer))["internal_direct"]

def call(*args, env=None, cwd=None):
    return subprocess.run(list(map(str, args)), env=env, cwd=cwd,
                          capture_output=True, text=True, check=False)

def produce(head=sha):
    result = call("python3", consumer, "emit", "--head", head)
    assert result.returncode == 0, result.stderr
    return result.stdout.strip()

def judge(body, head=sha, author="contributor"):
    pr = dict(number=1, body=body, head=dict(sha=head, ref="synthetic"), user=dict(login=author))
    return internal_direct(pr)

def falls_through(body, head=sha, author="contributor"):
    assert not judge(body, head, author), (body, head, author)
    env = os.environ.copy()
    env.update(PR_BODY=body or "", PR_HEAD_SHA=head, PR_AUTHOR=author,
               NM_EXEMPT_AUTHORS="", NM_EXEMPT_BOT_AUTHORS="false", NM_EXEMPT_HEAD_BRANCHES="")
    result = call("python3", verifier, env=env)
    assert result.returncode != 0, result.stdout
    assert "not raised through no-mistakes" in result.stderr, result.stderr

internal = produce()
assert judge(internal)
falls_through("Ordinary direct PR without pipeline provenance.")
for surface in ("product-facing", "mixed", "unknown"):
    falls_through(internal.replace('"surface":"internal-only"', f'"surface":"{surface}"'))
for mode in ("no-mistakes", "local-only"):
    falls_through(internal.replace('"mode":"direct-PR"', f'"mode":"{mode}"'))
falls_through(internal, other)
falls_through(internal + "\n" + internal)
falls_through(internal.replace("v1 ", "v2 "))
falls_through(internal.replace('"policy":"no-mistakes-prod-only",', ""))
falls_through(internal.replace('"surface":"internal-only"', '"surface":"internal-only","surface":"mixed"'))
falls_through(internal.replace('"surface":"internal-only"', '"surface":null'))
falls_through(internal.replace('"mode":"direct-PR"', '"mode":"direct-PR","unrecognized":true'))
falls_through(internal.replace(" -->", ""))
falls_through("<!-- firstmate-delivery:v1 {broken} -->")
falls_through("<!-- firstmate-delivery:v1 [] -->")
falls_through("This is internal-only tooling in bin/, direct-PR please.")
falls_through(None)
falls_through(internal.replace('"surface":"internal-only"', '"surface":"untrusted"'))
falls_through(internal.replace('"policy":"no-mistakes-prod-only"', '"policy":"unknown-policy"'))
falls_through(internal.replace(',"head_sha":"' + sha + '"', ""))
falls_through(internal.replace(sha, "short"))
# A valid record applies to any actor; identity never grants an exception.
for actor in ("contributor", "kunchenguid", "github-actions[bot]", "dependabot[bot]"):
    assert judge(internal, author=actor)
    falls_through("No delivery or pipeline declaration", author=actor)
assert judge(internal)
falls_through("")
assert judge(produce(head=other), other)
assert call("python3", consumer, "emit", "--head", "short").returncode != 0
print("PASS: actual producer/consumer admits internal-only, falls through for all non-internal/invalid/stale cases, independent of author")

# Generate the intake instructions and execute their actual producer command
# against a committed fixture, rather than asserting implementation text.
home = scratch / "intake-home"
(home / "data").mkdir(parents=True)
env = os.environ.copy()
env.update(FM_HOME=str(home), FM_ROOT_OVERRIDE=str(root))
result = call("bash", root / "bin/fm-brief.sh", "synthetic-internal", "synthetic",
              "--mode", "direct-PR", "--delivery-surface", "internal-only", env=env)
assert result.returncode == 0, result.stderr
brief = (home / "data/synthetic-internal/brief.md").read_text()
command = re.search(r"append the output of `([^`]+)`", brief).group(1)
repo = scratch / "fixture-repo"
repo.mkdir()
assert call("git", "init", repo).returncode == 0
assert call("git", "-C", repo, "-c", "user.name=Synthetic", "-c", "user.email=synthetic@example.invalid",
            "commit", "--allow-empty", "-m", "Fixture").returncode == 0
committed = call("git", "-C", repo, "rev-parse", "HEAD").stdout.strip()
emitted = call("bash", "-c", command, cwd=repo)
assert emitted.returncode == 0, emitted.stderr
assert judge(emitted.stdout, committed)
assert not judge(emitted.stdout, other)
invalid = call("bash", root / "bin/fm-brief.sh", "synthetic-invalid", "synthetic", "--mode", "direct-PR",
               "--delivery-surface", "not-a-surface", env=env)
assert invalid.returncode != 0
assert not (home / "data/synthetic-invalid/brief.md").exists()
print("PASS: semantic intake instructions produce a record accepted for the actual committed head")

# Drive the real check-live CLI against a bounded GitHub REST fixture. An old
# workflow event body/head must not override current forge facts on reruns.
state = {"body": internal, "head": sha, "status": 200}
class GitHub(BaseHTTPRequestHandler):
    def do_GET(self):
        assert self.path == "/repos/synthetic/project/pulls/1", self.path
        assert self.headers["Authorization"] == "Bearer synthetic-token"
        self.send_response(state["status"])
        self.end_headers()
        self.wfile.write(json.dumps(dict(number=1, body=state["body"], head=dict(sha=state["head"]))).encode())
    def log_message(self, *args):
        pass
server = HTTPServer(("127.0.0.1", 0), GitHub)
thread = threading.Thread(target=server.serve_forever, daemon=True)
thread.start()
event = scratch / "event.json"
output = scratch / "github-output"
mixed = internal.replace('"surface":"internal-only"', '"surface":"mixed"')
event.write_text(json.dumps(dict(pull_request=dict(number=1, body=mixed, head=dict(sha=other)))))
env = os.environ.copy()
env.update(GITHUB_EVENT_PATH=str(event), GITHUB_OUTPUT=str(output), GITHUB_REPOSITORY="synthetic/project",
           GITHUB_TOKEN="synthetic-token", GITHUB_API_URL=f"http://127.0.0.1:{server.server_port}")
def live(expected):
    output.write_text("")
    result = call("python3", consumer, "check-live", env=env)
    assert result.returncode == 0, result.stderr
    assert json.loads(result.stdout) == dict(direct=expected, requires_no_mistakes=not expected)
    assert output.read_text() == "direct=" + str(expected).lower() + "\n"
try:
    live(True)
    state["body"] = mixed
    live(False)
    state["body"] = ""
    live(False)
    state["body"] = internal
    state["head"] = other
    live(False)
    state["body"] = produce(head=other)
    live(True)
    state.update(body=emitted.stdout, head=committed)
    live(True)
    state["status"] = 403
    output.write_text("")
    result = call("python3", consumer, "check-live", env=env)
    assert result.returncode != 0
    assert "direct=true" not in output.read_text()
finally:
    server.shutdown()
    server.server_close()
    thread.join()
print("PASS: live normalized REST facts control reruns/reclassification/head changes; API failure fails closed")
PYTEST
pass "conditional delivery guardrail and pinned full-verifier fallback"
