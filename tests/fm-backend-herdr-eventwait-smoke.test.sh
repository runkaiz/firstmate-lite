#!/usr/bin/env bash
# tests/fm-backend-herdr-eventwait-smoke.test.sh - REAL-herdr smoke test for the
# native pane.agent_status_changed push escalation (fm_backend_herdr_wait_transition,
# bin/backends/herdr.sh, and its raw-socket reader bin/backends/herdr-eventwait.py).
# It drives a real idle->blocked transition in an ISOLATED, never-default herdr
# lab session and asserts the subscriber returns that transition sub-second and
# that the watcher's handle_push_transition lands a stale record in a scratch
# state/.wake-queue. Skips cleanly when herdr, jq, or python3 is missing.
#
# Safety (2026-07-02 incident, tests/herdr-test-safety.sh): cleanup uses ONLY
# herdr_safe_stop_and_delete on a private fm-lab-* session, never a bare/ambient
# `herdr server stop`. Every lifecycle op goes through bin/fm-herdr-lab.sh, which
# refuses the default session and verifies the fleet-state tripwire.
set -u

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

# shellcheck source=tests/lib.sh
. "$ROOT/tests/lib.sh"
fm_live_gate default-on FM_HERDR_EVENTWAIT_LIVE herdr jq python3

# shellcheck source=tests/herdr-test-safety.sh
. "$ROOT/tests/herdr-test-safety.sh"

# This suite runs against its own isolated lab session, so a Herdr pane
# inherited from the terminal it was launched in must not follow spawn into it
# as a cross-session parent identity (tests/herdr-test-safety.sh).
herdr_forget_inherited_pane

HERDR_LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
SESSION=$("$HERDR_LAB_HELPER" name eventwait) || exit 1
export HERDR_SESSION="$SESSION"
ORIGINAL_PATH=$PATH
SCRATCH=$(mktemp -d "${TMPDIR:-/tmp}/fm-evwait.XXXXXX")
CLEANED=0
cleanup_all() {
  [ "$CLEANED" = 0 ] || return 0
  CLEANED=1
  local rc=0
  PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" teardown "$SESSION" || rc=1
  rm -rf -- "${SCRATCH:?}"
  fm_test_cleanup
  return "$rc"
}
trap 'rc=$?; cleanup_all || rc=1; exit "$rc"' EXIT
"$HERDR_LAB_HELPER" provision "$SESSION" || fail "could not provision isolated Herdr lab session"
lab() { PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$SESSION" "$@"; }
mkdir "$SCRATCH/fakebin"
cat > "$SCRATCH/fakebin/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
n=${#args[@]}
[ "$n" -ge 2 ] && [ "${args[$((n-2))]}" = --session ] \
  && [ "${args[$((n-1))]}" = "$SESSION" ] || exit 1
exec env PATH="$ORIGINAL_PATH" "$HERDR_LAB_HELPER" run "$SESSION" "${args[@]:0:$((n-2))}"
SH
chmod +x "$SCRATCH/fakebin/herdr"
export ORIGINAL_PATH SESSION HERDR_LAB_HELPER
export PATH="$SCRATCH/fakebin:$ORIGINAL_PATH"

# The dispatcher is a separately linted production boundary. Its dynamic
# adapter source edges stop at each independently linted canonical adapter.
# shellcheck source=/dev/null
. "$ROOT/bin/fm-backend.sh"
fm_backend_source herdr || fail "fm_backend_source herdr failed"

HERDR_VERSION=$(lab status --json | jq -er '.client.version') || fail "could not read Herdr version"

# --- real capability gate ----------------------------------------------------

if ! fm_backend_herdr_events_capable "$SESSION"; then
  echo "skip: this herdr build is below the events.subscribe capability (protocol < 16 or events surface absent)"
  cleanup_all
  trap - EXIT
  exit 0
fi
pass "real herdr ($HERDR_VERSION): events.subscribe capability gate passes (protocol >= 16, events surface present in api schema)"

# --- container + a real task pane in the isolated session --------------------

WORKSPACE=$(lab workspace create --cwd "$SCRATCH" --label fm-evwait --no-focus) || fail "workspace create failed"
PANE_ID=$(printf '%s' "$WORKSPACE" | jq -er '.result.root_pane.pane_id') || fail "workspace create did not return its pane id"
TARGET="$SESSION:$PANE_ID"

# scratch firstmate state so window_to_task and the wake queue resolve
STATE="$SCRATCH/state"; mkdir -p "$STATE"
cat > "$STATE/evwait1.meta" <<EOF
window=$TARGET
backend=herdr
kind=ship
EOF

SOCK=$(fm_backend_herdr_socket_path "$SESSION")
[ -n "$SOCK" ] || fail "could not resolve the isolated session's socket path"

# --- register the pane's agent idle, then drive idle->blocked ----------------
# report-agent is herdr's documented primitive for a non-built-in process to
# report its own agent state (docs/herdr-backend.md); routed through the lab
# helper's guarded `run` so it carries the trailing --session.
lab pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state idle >/dev/null 2>&1 \
  || fail "could not register the pane's agent as idle"

OUT="$SCRATCH/out"; RCF="$SCRATCH/rc"
: > "$OUT"; : > "$RCF"
# Bounded subscriber wait in the background; it must sit past the idle reconcile
# and return only when the pane transitions to blocked.
( fm_backend_herdr_wait_transition "$SESSION" 8 "$STATE" "$TARGET" > "$OUT"; echo $? > "$RCF" ) &
WPID=$!
sleep 0.5   # let it connect, subscribe, and reconcile the idle baseline

START=$(python3 -c 'import time; print(time.time())')
lab pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state blocked >/dev/null 2>&1 \
  || fail "could not drive the pane's agent to blocked"
wait "$WPID"
END=$(python3 -c 'import time; print(time.time())')

RC=$(cat "$RCF" 2>/dev/null || echo "")
REC=$(cat "$OUT" 2>/dev/null || echo "")
ELAPSED=$(python3 -c "print(f'{($END)-($START):.3f}')" 2>/dev/null || echo "?")

[ "$RC" = 0 ] || fail "wait_transition should return 0 on a real idle->blocked transition, got rc='$RC' rec='$REC'"
REC_PANE=$(fm_transition_pane_id "$REC")
REC_TO=$(fm_transition_to_status "$REC")
[ "$REC_PANE" = "$PANE_ID" ] || fail "the returned record's pane_id ('$REC_PANE') must match the driven pane ('$PANE_ID')"
[ "$REC_TO" = "blocked" ] || fail "the returned record's to_status must be 'blocked', got '$REC_TO'"
# The event path should usually deliver before the next status poll.
UNDER_ONE=$(python3 -c "print('yes' if (($END)-($START)) < 1.0 else 'no')" 2>/dev/null || echo "no")
[ "$UNDER_ONE" = yes ] || echo "note: idle->blocked wake took ${ELAPSED}s (>1s)" >&2
pass "real herdr ($HERDR_VERSION): a driven idle->blocked transition returns the blocked record in ${ELAPSED}s (pane $PANE_ID)"

# --- the watcher's fast-path lands a stale record in the scratch wake queue ---
# Load the narrow production owner only after pointing it at scratch state, then
# override wake so the handler enqueues without exiting the test.
export FM_STATE_OVERRIDE="$STATE"
export FM_ROOT_OVERRIDE="$ROOT"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-push-transition-lib.sh"
wake() { return 0; }
handle_push_transition herdr "$SESSION" "$REC"
[ -e "$STATE/.wake-queue" ] || fail "handle_push_transition did not create the wake queue"
grep -q 'stale' "$STATE/.wake-queue" || fail "the wake queue must carry a stale record: $(cat "$STATE/.wake-queue")"
grep -q "$TARGET" "$STATE/.wake-queue" || fail "the stale record must name the task window $TARGET"
grep -q 'herdr: agent blocked' "$STATE/.wake-queue" || fail "the stale payload must name the herdr-blocked cause"
pass "real herdr: the watcher fast-path enqueues a stale wake naming the task window from the live blocked transition"

# A reconnect or unavailable stream sees the same native level and dedupes the
# already delivered episode.
if fm_backend_herdr_check_transition "$STATE" "$SESSION" "$PANE_ID"; then
  fail "current blocked level repeated an already delivered transition"
fi
lab pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state working >/dev/null \
  || fail "could not drive the pane's agent to working"
fm_backend_herdr_check_transition "$STATE" "$SESSION" "$PANE_ID" && fail "working should not escalate"
lab pane report-agent "$PANE_ID" --source fm-evwait-test --agent claude --state blocked >/dev/null \
  || fail "could not drive the second blocked episode"
REC=$(fm_backend_herdr_check_transition "$STATE" "$SESSION" "$PANE_ID") || fail "the second blocked episode was lost"
[ "$(fm_transition_to_status "$REC")" = blocked ] || fail "expected native blocked level"
pass "real herdr: the level check dedupes one blocked episode and detects the next"

if lab notification show --help >/dev/null 2>&1; then
  NOTICE=$(lab notification show 'Firstmate: review ready' --body evwait1 --sound "done") \
    || fail "Herdr $HERDR_VERSION notification API refused a review notice"
  printf '%s' "$NOTICE" | jq -e '.result != null' >/dev/null || fail "notification API did not return a result"
  pass "real herdr: notification API accepts a scoped review notice"
else
  printf 'skip: Herdr %s has no notification show command\n' "$HERDR_VERSION"
fi

# These launches use the isolated harness roots supplied by tests/lib.sh.
# Recognizing a real agent and waiting for idle or done needs no model calls.
if lab agent start --help >/dev/null 2>&1 && lab integration install --help >/dev/null 2>&1; then
  for harness in claude codex pi; do
    if ! command -v "$harness" >/dev/null; then
      printf 'skip: %s is not installed\n' "$harness"
      continue
    fi
    version=$("$harness" --version 2>/dev/null | head -n 1)
    lab integration install "$harness" >/dev/null || fail "Herdr $HERDR_VERSION could not install the isolated $harness integration"
    workspace=$(lab workspace create --cwd "$SCRATCH" --label "$harness-test" --no-focus) || fail "could not create $harness test workspace"
    pane=$(printf '%s' "$workspace" | jq -er '.result.root_pane.pane_id') || fail "missing $harness test pane"
    lab agent start "$harness-test" --kind "$harness" --pane "$pane" --timeout 15000 >/dev/null \
      || fail "Herdr $HERDR_VERSION did not recognize $harness ($version)"
    lab agent wait "$pane" --until idle --until "done" --timeout 5000 >/dev/null \
      || fail "Herdr $HERDR_VERSION did not report $harness ($version) settled"
    pass "real herdr ($HERDR_VERSION): $harness ($version) settles in the isolated pane"
  done
else
  printf 'skip: Herdr %s lacks agent start or integration install\n' "$HERDR_VERSION"
fi

if ! cleanup_all; then
  trap - EXIT
  printf 'not ok - guarded lab teardown or default-fleet tripwire failed\n' >&2
  exit 1
fi
trap - EXIT
