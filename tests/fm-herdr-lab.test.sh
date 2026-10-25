#!/usr/bin/env bash
# Behavior tests for bin/fm-herdr-lab.sh using a stateful fake Herdr client.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-herdr-lab)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FAKE_STATE="$TMP_ROOT/herdr-state"
FAKE_LOG="$TMP_ROOT/herdr.log"
TRIPWIRES="$TMP_ROOT/tripwires"
UNIT_STATE="$TMP_ROOT/units"
UNIT_LOG="$TMP_ROOT/units.log"
mkdir -p "$UNIT_STATE"
: > "$UNIT_LOG"
REAL_SLEEP=$(command -v sleep)
mkdir -p "$FAKE_STATE"
printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
: > "$FAKE_LOG"

cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$FM_FAKE_HERDR_LOG"
state=$FM_FAKE_HERDR_STATE
# Herdr reads --session only as an option, so it must end the arguments or
# sit immediately before the first -- delimiter.
last=
for arg in "$@"; do
  [ "$arg" != -- ] || break
  previous=$last
  last=$arg
done
[ "${previous:-}" = --session ] || { echo "fake herdr: missing --session before any -- delimiter" >&2; exit 90; }
session=$last
default_socket=$(cat "$state/default-socket")
lab_state=absent
[ ! -f "$state/$session" ] || lab_state=$(cat "$state/$session")

case "$1 ${2:-}" in
  "session list")
    if [ "$lab_state" = absent ] || [ "$lab_state" = deleted ]; then
      jq -nc --arg socket "$default_socket" '{sessions:[{default:true,name:"default",running:true,socket_path:$socket}]}'
    else
      running=false
      [ "$lab_state" = running ] && running=true
      jq -nc --arg socket "$default_socket" --arg name "$session" --argjson running "$running" \
        '{sessions:[{default:true,name:"default",running:true,socket_path:$socket},{default:false,name:$name,running:$running,socket_path:("/tmp/" + $name + ".sock")}]}'
    fi
    ;;
  "server --session")
    if [ "${FM_FAKE_HERDR_SERVER_DELAY:-0}" != 0 ]; then
      "$FM_FAKE_HERDR_REAL_SLEEP" "$FM_FAKE_HERDR_SERVER_DELAY"
    fi
    printf '%s\n' running > "$state/$session"
    ;;
  "status --json")
    if [ "$lab_state" = running ] && [ "${FM_FAKE_HERDR_STATUS_DOWN:-}" != 1 ]; then
      printf '%s\n' '{"server":{"running":true}}'
    else
      printf '%s\n' '{"server":{"running":false}}'
    fi
    ;;
  "session stop")
    [ "$3" = "$session" ] || exit 91
    printf '%s\n' stopped > "$state/$session"
    if [ -n "${FM_FAKE_UNIT_STATE:-}" ] && [ -f "$FM_FAKE_UNIT_STATE/$session.service.pid" ]; then
      printf 'server-stop %s\n' "$session" >> "$FM_FAKE_UNIT_LOG"
      [ "${FM_FAKE_UNIT_KEEP_MAIN:-}" = 1 ] || printf '0\n' > "$FM_FAKE_UNIT_STATE/$session.service.pid"
    fi
    ;;
  "session delete")
    [ "$3" = "$session" ] || exit 92
    [ "${FM_FAKE_HERDR_DELETE_FAIL:-}" != 1 ] || exit 93
    printf '%s\n' deleted > "$state/$session"
    ;;
  "terminal title")
    [ "${FM_FAKE_HERDR_TITLE_FAIL:-}" != 1 ] || exit 94
    reason=no_foreground_client
    [ ! -f "$state/$session.foreground" ] || reason=$(cat "$state/$session.foreground")
    jq -nc --arg reason "$reason" '{result:{reason:$reason,type:"client_window_title"}}'
    ;;
  *)
    printf '%s\n' '{"ok":true}'
    ;;
esac
SH
chmod +x "$FAKEBIN/herdr"


# The new provisioning option is exercised only through these fake systemd
# interfaces until its exact task-copy revision receives live authorization.
cat > "$FAKEBIN/systemd-run" <<'SH'
#!/usr/bin/env bash
set -eu
printf 'systemd-run %s\n' "$*" >> "$FM_FAKE_UNIT_LOG"
unit= description= exec_type=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    --unit=*) unit=${1#--unit=} ;;
    --description=*) description=${1#--description=} ;;
    --service-type=exec) exec_type=1 ;;
    --*) ;;
    *) break ;;
  esac
  shift
done
[ "$exec_type" = 1 ] && [ -n "$unit" ] && [ -n "$description" ] || exit 94
printf '%s\n' "$description" > "$FM_FAKE_UNIT_STATE/$unit.description"
printf '1234\n' > "$FM_FAKE_UNIT_STATE/$unit.pid"
if [ "${FM_FAKE_UNIT_START_FAIL:-}" = 1 ]; then
  printf '0\n' > "$FM_FAKE_UNIT_STATE/$unit.pid"
  exit 42
fi
exec "$@"
SH
cat > "$FAKEBIN/systemctl" <<'SH'
#!/usr/bin/env bash
set -eu
[ "${FM_FAKE_UNIT_UNREADABLE:-}" != 1 ] || exit 95
[ "$1" = --user ] || exit 96
shift
command=$1
shift
case "$command" in
  show)
    unit=$1
    case "$2" in
      --property=LoadState)
        if [ -f "$FM_FAKE_UNIT_STATE/$unit.description" ]; then echo loaded; else echo not-found; fi ;;
      --property=Description) cat "$FM_FAKE_UNIT_STATE/$unit.description" ;;
      --property=MainPID) cat "$FM_FAKE_UNIT_STATE/$unit.pid" ;;
      *) exit 97 ;;
    esac
    ;;
  is-active)
    [ "$1" = --quiet ] || exit 98
    [ "${FM_FAKE_UNIT_INACTIVE:-}" != 1 ] && [ "$(cat "$FM_FAKE_UNIT_STATE/$2.pid")" != 0 ] ;;
  stop)
    printf 'unit-stop %s\n' "$1" >> "$FM_FAKE_UNIT_LOG"
    [ "${FM_FAKE_UNIT_STOP_FAIL:-}" != 1 ] || exit 99
    rm -f "$FM_FAKE_UNIT_STATE/$1.description" "$FM_FAKE_UNIT_STATE/$1.pid"
    ;;
  *) exit 100 ;;
esac
SH
chmod +x "$FAKEBIN/systemd-run" "$FAKEBIN/systemctl"

# shellcheck source=/dev/null
. "$ROOT/bin/fm-herdr-lab.sh"

run_with_fake() {
  PATH="$FAKEBIN:$PATH" \
    FM_FAKE_UNIT_STATE="$UNIT_STATE" \
    FM_FAKE_UNIT_LOG="$UNIT_LOG" \
    FM_FAKE_HERDR_STATE="$FAKE_STATE" \
    FM_FAKE_HERDR_LOG="$FAKE_LOG" \
    FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" \
    FM_FAKE_HERDR_SERVER_DELAY="${FM_FAKE_HERDR_SERVER_DELAY:-0}" \
    FM_FAKE_HERDR_FAST_POLL="${FM_FAKE_HERDR_FAST_POLL:-}" \
    FM_FAKE_HERDR_DELETE_FAIL="${FM_FAKE_HERDR_DELETE_FAIL:-}" \
    FM_FAKE_HERDR_TITLE_FAIL="${FM_FAKE_HERDR_TITLE_FAIL:-}" \
    FM_HERDR_LAB_STATE_DIR="$TRIPWIRES" \
    "$@"
}

test_refuses_unsafe_names() {
  local status=0 generated
  fm_herdr_lab_validate_name default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "literal default must be refused"
  status=0
  fm_herdr_lab_validate_name arbitrary-session >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "non-lab prefix must be refused"
  fm_herdr_lab_validate_name fm-lab-safe-123 || fail "valid lab session name was refused"
  generated=$(fm_herdr_lab_name fm-autodetect-smoke-concurrency-h3)
  fm_herdr_lab_validate_name "$generated" || fail "generated lab session name was refused"
  [ "${#generated}" -le 40 ] || fail "generated lab session name is too long for Herdr socket paths: $generated"
  pass "fm-herdr-lab: names fail closed and require the lab prefix"
}

test_provision_run_and_guarded_teardown() {
  local name='' line_count status=0 stop_line delete_line
  name="fm-lab-behavior-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "provision failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "provision did not start the named lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "provision did not record the fleet-state tripwire"

  run_with_fake fm_herdr_lab_cli "$name" workspace list >/dev/null || fail "safe run command failed"
  run_with_fake fm_herdr_lab_cli "$name" server >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "bare server start outside provision must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "server-global stop must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "direct session delete must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" status --session=default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "caller-supplied equals-form session flag must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --handoff server stop >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting server stop past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --no-session session delete "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option shifting session delete past the guard must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" --remote host workspace list >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading option subverting session isolation must be refused"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded teardown failed"
  [ "$(cat "$FAKE_STATE/$name")" = deleted ] || fail "teardown did not delete the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful teardown left its tripwire behind"

  while IFS= read -r line; do
    case "$line" in
      *"--session $name") : ;;
      *) fail "Herdr call lacks a trailing lab session: $line" ;;
    esac
  done < "$FAKE_LOG"
  line_count=$(wc -l < "$FAKE_LOG" | tr -d ' ')
  stop_line=$(grep -n "^session stop $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  delete_line=$(grep -n "^session delete $name --json --session $name$" "$FAKE_LOG" | cut -d: -f1)
  if [ -z "$stop_line" ] || [ -z "$delete_line" ] || [ "$line_count" -le "$delete_line" ]; then
    fail "teardown did not emit explicit stop/delete followed by the after tripwire"
  fi
  sed -n "$((stop_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "stop was not immediately preceded by a fresh refuse-default session list"
  sed -n "$((delete_line - 1))p" "$FAKE_LOG" | grep -F "session list --json --session $name" >/dev/null \
    || fail "delete was not immediately preceded by a fresh refuse-default session list"
  pass "fm-herdr-lab: provisioning, scoped calls, guarded teardown, and fleet tripwire are deterministic"
}

test_run_scopes_session_before_double_dash() {
  local name="fm-lab-double-dash-$$" status=0 before after
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "double-dash fixture provision failed"

  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_cli "$name" agent start probe --kind pi --pane w1:p1 >/dev/null \
    || fail "run without a -- delimiter failed"
  run_with_fake fm_herdr_lab_cli "$name" agent start probe --kind pi --pane w1:p1 \
    -- --no-session -- --version >/dev/null || fail "run with a -- delimiter failed"
  grep -Fx -- "agent start probe --kind pi --pane w1:p1 --session $name" "$FAKE_LOG" >/dev/null \
    || fail "run without a -- delimiter did not append a trailing lab session"
  grep -Fx -- "agent start probe --kind pi --pane w1:p1 --session $name -- --no-session -- --version" "$FAKE_LOG" >/dev/null \
    || fail "run did not place the lab session before the first -- delimiter"

  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_cli "$name" agent start probe --kind pi --pane w1:p1 \
    -- --session default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a caller --session after the -- delimiter must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" agent start probe --kind pi --pane w1:p1 \
    --session=default -- --version >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a caller --session before the -- delimiter must be refused"
  status=0
  run_with_fake fm_herdr_lab_cli "$name" -- agent start probe --kind pi --pane w1:p1 >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a leading -- delimiter must be refused"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "a refused double-dash run reached Herdr"

  run_with_fake fm_herdr_lab_teardown "$name" || fail "double-dash fixture teardown failed"
  pass "fm-herdr-lab: run keeps the lab session a Herdr option before any -- delimiter"
}

test_missing_tripwire_blocks_destruction() {
  local name="fm-lab-no-tripwire-$$" status=0 before after
  printf '%s\n' running > "$FAKE_STATE/$name"
  : > "$FAKE_LOG"
  before=$(wc -l < "$FAKE_LOG")
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "missing tripwire must refuse teardown"
  after=$(wc -l < "$FAKE_LOG")
  [ "$before" = "$after" ] || fail "missing tripwire reached Herdr instead of refusing before destructive calls"
  pass "fm-herdr-lab: missing tripwire refuses teardown before any Herdr call"
}

test_changed_default_trips_after_teardown() {
  local name="fm-lab-tripwire-change-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "tripwire fixture provision failed"
  printf '%s\n' '/changed/default.sock' > "$FAKE_STATE/default-socket"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default fleet state must fail teardown"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed tripwire should retain evidence"
  printf '%s\n' '/home/test/.config/herdr/herdr.sock' > "$FAKE_STATE/default-socket"
  rm -f "$TRIPWIRES/$name.fleet-state.json"
  pass "fm-herdr-lab: changed default fleet state is a hard failure"
}

test_stopped_owned_lab_can_reprovision() {
  local name="fm-lab-reprovision-$$"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "initial provision failed"
  run_with_fake fm_herdr_lab_stop "$name" || fail "guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "guarded stop did not stop the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "stop removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_provision "$name" || fail "re-provision after guarded stop failed"
  [ "$(cat "$FAKE_STATE/$name")" = running ] || fail "re-provision did not restart the stopped lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "re-provision removed the lab ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after re-provision failed"
  pass "fm-herdr-lab: an owned stopped lab can re-provision safely"
}

test_failed_delete_retains_tripwire() {
  local name="fm-lab-delete-failure-$$" status=0
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision "$name" || fail "delete-failure fixture provision failed"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed delete must fail teardown"
  [ "$(cat "$FAKE_STATE/$name")" = stopped ] || fail "failed delete unexpectedly removed the lab session"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed delete removed the ownership tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "retry after failed delete did not clean up the lab session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "successful retry left the ownership tripwire behind"
  pass "fm-herdr-lab: failed deletion retains ownership until absence is confirmed"
}

test_timed_out_provision_cancels_late_launch() {
  local name="fm-lab-late-launch-$$" status=0
  cat > "$FAKEBIN/sleep" <<'SH'
#!/usr/bin/env bash
if [ "${FM_FAKE_HERDR_FAST_POLL:-}" = 1 ]; then
  while [ -n "${FM_FAKE_HERDR_WAIT_MARKER:-}" ] && [ ! -f "$FM_FAKE_HERDR_WAIT_MARKER" ]; do
    "$FM_FAKE_HERDR_REAL_SLEEP" 0.01
  done
  exit 0
fi
exec "$FM_FAKE_HERDR_REAL_SLEEP" "$@"
SH
  chmod +x "$FAKEBIN/sleep"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_SERVER_DELAY=30 \
    run_with_fake fm_herdr_lab_provision "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "timed-out provision must fail"
  assert_present "$TRIPWIRES/$name.fleet-state.json" \
    "timed-out provision must retain its tripwire until teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after timed-out provision failed"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" \
    "teardown after timed-out provision did not remove its tripwire"
  "$REAL_SLEEP" 1.1
  if [ -f "$FAKE_STATE/$name" ] && [ "$(cat "$FAKE_STATE/$name")" = running ]; then
    fail "timed-out provision left a late-starting lab session after teardown"
  fi
  pass "fm-herdr-lab: timed-out provisioning cancels the launch before teardown"
}


# The pty attachment itself needs a real Herdr client, so the live guard
# tests/fm-herdr-attached-viewer-live-e2e.test.sh owns that proof. What is
# portable is who the helper will ever attach to, and who it will signal.
test_viewer_refuses_unowned_sessions() {
  local name="fm-lab-viewer-guard-$$" status=0 out
  : > "$FAKE_LOG"
  out=$(run_with_fake fm_herdr_lab_viewer_start "$name" 2>&1) || status=$?
  expect_code 1 "$status" "a session without an ownership tripwire must not be attached to"
  assert_contains "$out" "does not own" \
    "the viewer refusal did not name the missing ownership record"
  [ ! -s "$FAKE_LOG" ] \
    || fail "the unowned-session refusal reached Herdr instead of refusing first"

  status=0
  run_with_fake fm_herdr_lab_viewer_start default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "the default session must never be attached to"
  pass "fm-herdr-lab: the viewer attaches only to a session this lab owns"
}

start_viewer_fixture() {
  local pair=$1
  (
    "$REAL_SLEEP" 20 &
    printf '%s\n' "$!" > "$pair"
    wait
  ) &
  FIXTURE_LAUNCHER_PID=$!
  while [ ! -s "$pair" ]; do
    "$REAL_SLEEP" 0.01
  done
  FIXTURE_VIEWER_PID=$(cat "$pair")
}

write_viewer_record() {
  local record=$1 launcher_pid=$2 viewer_pid=$3 launcher_start viewer_start
  launcher_start=$(fm_herdr_lab_process_start "$launcher_pid") || fail "could not identify launcher fixture process"
  viewer_start=$(fm_herdr_lab_process_start "$viewer_pid") || fail "could not identify viewer fixture process"
  printf 'launcher_pid=%s\nlauncher_start=%s\nviewer_pid=%s\nviewer_start=%s\n' \
    "$launcher_pid" "$launcher_start" "$viewer_pid" "$viewer_start" > "$record"
}

test_viewer_start_cancels_an_unrecorded_launcher() {
  local name="fm-lab-viewer-late-$$" out status=0 launcher_pid
  local started="$TMP_ROOT/viewer-launcher-started"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-late fixture provision failed"
  cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_FAKE_VIEWER_STARTED"
exec "$FM_FAKE_HERDR_REAL_SLEEP" 20
SH
  chmod +x "$FAKEBIN/python3"
  out=$(FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_WAIT_MARKER="$started" \
    FM_FAKE_VIEWER_STARTED="$started" run_with_fake fm_herdr_lab_viewer_start "$name" 2>&1) || status=$?
  rm -f "$FAKEBIN/python3"
  expect_code 1 "$status" "an unrecorded launcher must not outlive viewer start"
  assert_present "$started" "delayed viewer launcher did not start"
  launcher_pid=$(cat "$started")
  kill -0 "$launcher_pid" 2>/dev/null && fail "timed-out viewer launcher remained alive"
  assert_contains "$out" "did not become the foreground client" "launcher timeout was unclear"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-late fixture teardown failed"
  pass "fm-herdr-lab: timed-out viewer startup cancels its exact launcher"
}

test_viewer_timeout_allows_launcher_escalation() {
  local launcher_pid started="$TMP_ROOT/viewer-grace-started"
  local terminating="$TMP_ROOT/viewer-grace-terminating" completed="$TMP_ROOT/viewer-grace-completed"
  cat > "$FAKEBIN/viewer-launcher" <<'SH'
#!/usr/bin/env bash
trap 'printf "" > "$FM_FAKE_VIEWER_TERMINATING"; "$FM_FAKE_HERDR_REAL_SLEEP" 1.2; printf "" > "$FM_FAKE_VIEWER_COMPLETED"; exit 0' TERM
printf '' > "$FM_FAKE_VIEWER_STARTED"
while :; do
  "$FM_FAKE_HERDR_REAL_SLEEP" 0.1
done
SH
  chmod +x "$FAKEBIN/viewer-launcher"
  FM_FAKE_HERDR_REAL_SLEEP="$REAL_SLEEP" FM_FAKE_VIEWER_STARTED="$started" \
    FM_FAKE_VIEWER_TERMINATING="$terminating" FM_FAKE_VIEWER_COMPLETED="$completed" \
    "$FAKEBIN/viewer-launcher" &
  launcher_pid=$!
  while [ ! -f "$started" ]; do
    "$REAL_SLEEP" 0.01
  done
  run_with_fake fm_herdr_lab_cancel_viewer_launcher "$launcher_pid"
  assert_present "$terminating" "timed-out viewer launcher did not receive TERM"
  assert_present "$completed" "viewer launcher was killed before completing child escalation"
  pass "fm-herdr-lab: startup timeout allows launcher child escalation"
}

test_viewer_start_requires_its_owned_process() {
  local name="fm-lab-viewer-ownership-$$" out status=0 marker="$TMP_ROOT/viewer-launched"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-ownership fixture provision failed"
  printf '%s\n' cleared > "$FAKE_STATE/$name.foreground"
  cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
: > "$FM_FAKE_VIEWER_MARKER"
exit 0
SH
  chmod +x "$FAKEBIN/python3"
  out=$(FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_VIEWER_MARKER="$marker" \
    run_with_fake fm_herdr_lab_viewer_start "$name" 2>&1) || status=$?
  rm -f "$FAKEBIN/python3"
  expect_code 1 "$status" "a foreign foreground client must not satisfy viewer start"
  assert_present "$marker" "viewer ownership fixture did not launch"
  assert_contains "$out" "did not become the foreground client" "ownership failure did not time out clearly"
  assert_not_contains "$out" "viewer attached" "start claimed a foreign foreground client as its own"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-ownership fixture teardown failed"
  pass "fm-herdr-lab: viewer start requires an identity-matched owned process"
}

test_viewer_stop_only_signals_owned_processes() {
  local name="fm-lab-viewer-stop-$$" record status=0 holder_pid pair="$TMP_ROOT/viewer-stop-pair"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-stop fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")

  # No record: a client attached by someone else is not ours to kill.
  printf '%s\n' cleared > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_viewer_stop "$name" \
    || fail "stopping with no recorded viewer must succeed without touching a foreign client"
  [ "$(cat "$FAKE_STATE/$name.foreground")" = cleared ] \
    || fail "an unrecorded foreground client was detached by the lab helper"

  # A recorded viewer is signalled until it exits and the session reports no
  # foreground client again.
  start_viewer_fixture "$pair"
  write_viewer_record "$record" "$FIXTURE_LAUNCHER_PID" "$FIXTURE_VIEWER_PID"
  status=0
  FM_FAKE_HERDR_FAST_POLL=1 run_with_fake fm_herdr_lab_viewer_stop "$name" \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "stop must fail while the session still reports a foreground client"
  wait "$FIXTURE_LAUNCHER_PID" 2>/dev/null || true
  kill -0 "$FIXTURE_VIEWER_PID" 2>/dev/null && fail "stop left the recorded viewer process running"
  assert_present "$record" "a failed detach discarded the viewer record it still needs"

  sleep 20 &
  holder_pid=$!
  printf 'launcher_pid=%s\nlauncher_start=not-this-process\nviewer_pid=%s\nviewer_start=not-this-process\n' \
    "$holder_pid" "$holder_pid" > "$record"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_viewer_stop "$name" || fail "stop rejected a stale process record"
  kill -0 "$holder_pid" 2>/dev/null || fail "stop signalled a PID whose recorded identity did not match"
  kill "$holder_pid" 2>/dev/null || true
  wait "$holder_pid" 2>/dev/null || true

  run_with_fake fm_herdr_lab_viewer_stop "$name" || fail "stop failed once the client had detached"
  assert_absent "$record" "a confirmed detach left the viewer record behind"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after viewer stop failed"
  pass "fm-herdr-lab: viewer stop signals only recorded processes and confirms the detach"
}

test_viewer_stop_requires_the_recorded_parent() {
  local name="fm-lab-viewer-parent-$$" record launcher_pid viewer_pid
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-parent fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")
  sleep 20 &
  launcher_pid=$!
  sleep 20 &
  viewer_pid=$!
  write_viewer_record "$record" "$launcher_pid" "$viewer_pid"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_viewer_stop "$name" || fail "parent-mismatch stop failed"
  kill -0 "$launcher_pid" 2>/dev/null || fail "stop signalled a launcher without its recorded child"
  kill -0 "$viewer_pid" 2>/dev/null || fail "stop signalled a viewer outside the recorded launcher"
  kill "$launcher_pid" "$viewer_pid" 2>/dev/null || true
  wait "$launcher_pid" 2>/dev/null || true
  wait "$viewer_pid" 2>/dev/null || true
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-parent fixture teardown failed"
  pass "fm-herdr-lab: viewer ownership requires the recorded parent"
}

test_interrupted_viewer_start_cancels_launcher() {
  local name="fm-lab-viewer-interrupt-$$" command_pid launcher_pid status=0
  local started="$TMP_ROOT/viewer-interrupt-started" attached="$TMP_ROOT/viewer-interrupt-attached"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-interrupt fixture provision failed"
  cat > "$FAKEBIN/python3" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$$" > "$FM_FAKE_VIEWER_STARTED"
"$FM_FAKE_HERDR_REAL_SLEEP" 0.5
: > "$FM_FAKE_VIEWER_ATTACHED"
printf '%s\n' cleared > "$FM_FAKE_HERDR_STATE/$FM_FAKE_VIEWER_SESSION.foreground"
exec "$FM_FAKE_HERDR_REAL_SLEEP" 20
SH
  chmod +x "$FAKEBIN/python3"
  FM_FAKE_VIEWER_STARTED="$started" FM_FAKE_VIEWER_ATTACHED="$attached" \
    FM_FAKE_VIEWER_SESSION="$name" run_with_fake exec "$ROOT/bin/fm-herdr-lab.sh" \
    viewer start "$name" >/dev/null 2>&1 &
  command_pid=$!
  while [ ! -f "$started" ]; do
    "$REAL_SLEEP" 0.01
  done
  launcher_pid=$(cat "$started")
  kill -TERM "$command_pid"
  wait "$command_pid" || status=$?
  rm -f "$FAKEBIN/python3"
  [ "$status" -ne 0 ] || fail "interrupted viewer start unexpectedly succeeded"
  "$REAL_SLEEP" 0.6
  kill -0 "$launcher_pid" 2>/dev/null && fail "interrupted viewer start left its launcher running"
  assert_absent "$attached" "interrupted viewer start attached after its command exited"
  [ ! -f "$FAKE_STATE/$name.foreground" ] || fail "interrupted viewer start left a foreground client"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "viewer-interrupt fixture teardown failed"
  pass "fm-herdr-lab: interrupted viewer start cancels its launcher"
}

test_teardown_refuses_while_viewer_attached() {
  local name="fm-lab-viewer-teardown-$$" record status=0 pair="$TMP_ROOT/viewer-teardown-pair"
  run_with_fake fm_herdr_lab_provision "$name" || fail "viewer-teardown fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")
  printf '%s\n' cleared > "$FAKE_STATE/$name.foreground"
  start_viewer_fixture "$pair"
  write_viewer_record "$record" "$FIXTURE_LAUNCHER_PID" "$FIXTURE_VIEWER_PID"
  : > "$FAKE_LOG"
  FM_FAKE_HERDR_FAST_POLL=1 run_with_fake fm_herdr_lab_teardown "$name" \
    >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "teardown must refuse while an owned viewer is still attached"
  [ "$(cat "$FAKE_STATE/$name")" = running ] \
    || fail "the refused teardown stopped the lab session anyway"
  assert_no_grep "session delete $name" "$FAKE_LOG" \
    "the refused teardown still reached the destructive delete"

  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after the viewer detached failed"
  pass "fm-herdr-lab: teardown refuses to destroy a session an attached viewer still holds"
}

test_viewer_stop_retains_record_when_detach_is_unreadable() {
  local name="fm-lab-viewer-unreadable-$$" record status=0
  run_with_fake fm_herdr_lab_provision "$name" || fail "unreadable-detach fixture provision failed"
  record=$(run_with_fake fm_herdr_lab_viewer_record_path "$name")
  printf 'launcher_pid=99999999\nlauncher_start=stale\nviewer_pid=99999999\nviewer_start=stale\n' > "$record"
  FM_FAKE_HERDR_FAST_POLL=1 FM_FAKE_HERDR_TITLE_FAIL=1 \
    run_with_fake fm_herdr_lab_viewer_stop "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an unreadable detach result on a running session must fail closed"
  assert_present "$record" "an unreadable detach result discarded the ownership record"
  printf '%s\n' no_foreground_client > "$FAKE_STATE/$name.foreground"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "teardown after a confirmed detach failed"
  pass "fm-herdr-lab: unreadable detach results fail closed on running sessions"
}

test_viewer_launcher_refuses_unsafe_arguments() {
  local launcher="$ROOT/bin/fm-herdr-lab-viewer.py" status=0
  command -v python3 >/dev/null 2>&1 || { pass "fm-herdr-lab: viewer launcher argument guard (skipped, no python3)"; return; }
  python3 "$launcher" default "$TMP_ROOT/pid" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the launcher must refuse the default session"
  status=0
  python3 "$launcher" arbitrary-session "$TMP_ROOT/pid" >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the launcher must refuse a non-lab session name"
  status=0
  python3 "$launcher" fm-lab-args relative-pidfile >/dev/null 2>&1 || status=$?
  expect_code 2 "$status" "the launcher must refuse a relative pidfile path"
  assert_absent "$TMP_ROOT/pid" "a refused launch still wrote a pid record"
  pass "fm-herdr-lab: the viewer launcher refuses unsafe sessions and pidfiles"
}


test_systemd_exec_provision_and_cleanup() {
  local name="fm-lab-exec-ready-$$" stop_line unit_line
  : > "$UNIT_LOG"
  run_with_fake bash "$ROOT/bin/fm-herdr-lab.sh" provision-systemd-exec "$name" || fail "Type=exec CLI provision failed"
  assert_present "$TRIPWIRES/$name.systemd-owner" "unit ownership was not recorded"
  grep -F -- "--service-type=exec" "$UNIT_LOG" >/dev/null || fail "provision did not request Type=exec"
  grep -F -- "$FAKEBIN/herdr server --session $name" "$UNIT_LOG" >/dev/null || fail "unit does not directly execute scoped foreground Herdr"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "systemd provision omitted the default tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "Type=exec guarded teardown failed"
  assert_absent "$TRIPWIRES/$name.systemd-owner" "unit ownership survived successful cleanup"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "tripwire survived successful cleanup"
  assert_absent "$UNIT_STATE/$name.service.description" "owned unit survived cleanup"
  stop_line=$(grep -n "^server-stop $name$" "$UNIT_LOG" | cut -d: -f1)
  unit_line=$(grep -n "^unit-stop $name.service$" "$UNIT_LOG" | cut -d: -f1)
  [ -n "$stop_line" ] && [ -n "$unit_line" ] && [ "$stop_line" -lt "$unit_line" ] || fail "unit stop preceded guarded server stop"
  pass "fm-herdr-lab: Type=exec directly launches scoped Herdr and cleans server before unit"
}

test_systemd_exec_refuses_default_and_foreign_units() {
  local name="fm-lab-exec-foreign-$$" status=0
  : > "$UNIT_LOG"
  : > "$FAKE_LOG"
  run_with_fake fm_herdr_lab_provision_systemd_exec default >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "Type=exec must refuse default"
  [ ! -s "$UNIT_LOG" ] && [ ! -s "$FAKE_LOG" ] || fail "default refusal reached a lifecycle interface"
  printf 'foreign\n' > "$UNIT_STATE/$name.service.description"
  status=0
  run_with_fake fm_herdr_lab_provision_systemd_exec "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "Type=exec must refuse an existing foreign unit"
  [ ! -s "$UNIT_LOG" ] && [ ! -s "$FAKE_LOG" ] || fail "foreign unit refusal tried to provision or destroy a session"
  assert_absent "$TRIPWIRES/$name.fleet-state.json" "foreign unit refusal claimed ownership"
  name="$name-record"
  printf 'stale ownership\n' > "$TRIPWIRES/$name.systemd-owner"
  status=0
  run_with_fake fm_herdr_lab_provision_systemd_exec "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "pre-existing ownership records must not be overwritten"
  [ ! -s "$UNIT_LOG" ] && [ ! -s "$FAKE_LOG" ] || fail "ownership refusal still touched a lifecycle interface"
  assert_present "$TRIPWIRES/$name.systemd-owner" "ownership refusal discarded evidence"
  pass "fm-herdr-lab: Type=exec refuses default, pre-existing units, and stale ownership before provisioning"
}

test_systemd_exec_refuses_unowned_running_lab() {
  local name="fm-lab-exec-running-$$" status=0
  printf 'running\n' > "$FAKE_STATE/$name"
  : > "$UNIT_LOG"
  run_with_fake fm_herdr_lab_provision_systemd_exec "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "Type=exec must not adopt an unowned running lab"
  [ ! -s "$UNIT_LOG" ] || fail "unowned running lab still started a service"
  assert_absent "$TRIPWIRES/$name.systemd-owner" "unowned lab gained a unit ownership record"
  pass "fm-herdr-lab: Type=exec preserves running-session ownership refusal"
}

test_systemd_exec_readiness_failure_retains_cleanup_records() {
  local name="fm-lab-exec-notready-$$" status=0
  : > "$UNIT_LOG"
  FM_FAKE_HERDR_STATUS_DOWN=1 FM_FAKE_HERDR_FAST_POLL=1 \
    run_with_fake fm_herdr_lab_provision_systemd_exec "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "a running unit without an available lab API must not count as ready"
  assert_present "$TRIPWIRES/$name.systemd-owner" "readiness failure lost unit ownership"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "readiness failure lost its tripwire"
  assert_no_grep '^unit-stop ' "$UNIT_LOG" "readiness timeout killed the unit outside guarded teardown"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded cleanup after readiness failure failed"
  name="$name-inactive"
  status=0
  FM_FAKE_UNIT_INACTIVE=1 FM_FAKE_HERDR_FAST_POLL=1 \
    run_with_fake fm_herdr_lab_provision_systemd_exec "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "an available API without an active unit must not count as ready"
  assert_present "$TRIPWIRES/$name.systemd-owner" "inactive-unit failure lost ownership"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "guarded cleanup after inactive-unit readiness failure failed"
  pass "fm-herdr-lab: Type=exec readiness requires both API and active unit and preserves cleanup records"
}

test_systemd_exec_start_failure_is_recoverable() {
  local name="fm-lab-exec-startfail-$$" status=0
  FM_FAKE_UNIT_START_FAIL=1 run_with_fake fm_herdr_lab_provision_systemd_exec "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "unit startup failure must fail provision"
  assert_present "$TRIPWIRES/$name.systemd-owner" "failed start discarded ownership"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "failed-start unit could not be cleaned after server absence"
  assert_absent "$TRIPWIRES/$name.systemd-owner" "failed-start cleanup retained ownership"
  pass "fm-herdr-lab: failed Type=exec startup retains recoverable ownership"
}

test_systemd_exec_cleanup_refuses_replaced_or_live_unit() {
  local name="fm-lab-exec-replaced-$$" status=0
  run_with_fake fm_herdr_lab_provision_systemd_exec "$name" || fail "unit replacement fixture failed"
  : > "$UNIT_LOG"
  FM_FAKE_UNIT_UNREADABLE=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "unreadable unit state must refuse cleanup"
  assert_no_grep '^unit-stop ' "$UNIT_LOG" "unreadable state still reached unit stop"
  assert_present "$TRIPWIRES/$name.systemd-owner" "unreadable state lost ownership"
  status=0
  printf 'foreign replacement\n' > "$UNIT_STATE/$name.service.description"
  : > "$UNIT_LOG"
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "replacement unit must refuse cleanup"
  assert_no_grep '^unit-stop ' "$UNIT_LOG" "cleanup stopped a replacement unit"
  assert_present "$TRIPWIRES/$name.systemd-owner" "replacement refusal discarded ownership evidence"
  cp "$TRIPWIRES/$name.systemd-owner" "$UNIT_STATE/$name.service.description"
  printf '1234\n' > "$UNIT_STATE/$name.service.pid"
  status=0
  FM_FAKE_HERDR_FAST_POLL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "unit cleanup must refuse a surviving MainPID even when the session is absent"
  assert_no_grep '^unit-stop ' "$UNIT_LOG" "unit cleanup killed a surviving MainPID"
  printf '0\n' > "$UNIT_STATE/$name.service.pid"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "cleanup did not converge after the owned main process exited"
  pass "fm-herdr-lab: cleanup refuses replaced units and any surviving MainPID"
}

test_systemd_exec_cleanup_preserves_failed_delete_and_tripwire() {
  local name="fm-lab-exec-delete-$$" status=0
  run_with_fake fm_herdr_lab_provision_systemd_exec "$name" || fail "unit delete fixture failed"
  : > "$UNIT_LOG"
  FM_FAKE_HERDR_DELETE_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed session delete must refuse unit cleanup"
  assert_no_grep '^unit-stop ' "$UNIT_LOG" "unit was stopped before session removal"
  assert_present "$TRIPWIRES/$name.systemd-owner" "failed deletion discarded unit ownership"
  printf '/changed/default.sock\n' > "$FAKE_STATE/default-socket"
  status=0
  run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "changed default must refuse unit cleanup"
  assert_no_grep '^unit-stop ' "$UNIT_LOG" "changed default did not prevent unit cleanup"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "changed default lost its tripwire"
  printf '/home/test/.config/herdr/herdr.sock\n' > "$FAKE_STATE/default-socket"
  status=0
  FM_FAKE_UNIT_STOP_FAIL=1 run_with_fake fm_herdr_lab_teardown "$name" >/dev/null 2>&1 || status=$?
  expect_code 1 "$status" "failed unit stop must retain ownership and tripwire"
  assert_present "$TRIPWIRES/$name.systemd-owner" "failed unit stop discarded ownership"
  assert_present "$TRIPWIRES/$name.fleet-state.json" "failed unit stop discarded tripwire"
  run_with_fake fm_herdr_lab_teardown "$name" || fail "unit cleanup retry failed"
  pass "fm-herdr-lab: deletion, tripwire, and unit-stop failures retain safe cleanup ownership"
}


test_refuses_unsafe_names
test_provision_run_and_guarded_teardown
test_run_scopes_session_before_double_dash
test_missing_tripwire_blocks_destruction
test_changed_default_trips_after_teardown
test_stopped_owned_lab_can_reprovision
test_failed_delete_retains_tripwire
test_timed_out_provision_cancels_late_launch
test_viewer_refuses_unowned_sessions
test_viewer_start_cancels_an_unrecorded_launcher
test_viewer_timeout_allows_launcher_escalation
test_viewer_start_requires_its_owned_process
test_viewer_stop_only_signals_owned_processes
test_viewer_stop_requires_the_recorded_parent
test_interrupted_viewer_start_cancels_launcher
test_teardown_refuses_while_viewer_attached
test_viewer_stop_retains_record_when_detach_is_unreadable
test_viewer_launcher_refuses_unsafe_arguments

test_systemd_exec_provision_and_cleanup
test_systemd_exec_refuses_default_and_foreign_units
test_systemd_exec_refuses_unowned_running_lab
test_systemd_exec_readiness_failure_retains_cleanup_records
test_systemd_exec_start_failure_is_recoverable
test_systemd_exec_cleanup_refuses_replaced_or_live_unit
test_systemd_exec_cleanup_preserves_failed_delete_and_tripwire
