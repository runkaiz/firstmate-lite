#!/usr/bin/env bash
# Behavioral coverage for bounded inactive terminal-outcome reconciliation.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

RECON="$ROOT/bin/fm-inactive-reconcile.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
GRANT="$ROOT/bin/fm-wake-grant.sh"
WATCH="$ROOT/bin/fm-watch.sh"
TMP_ROOT=$(fm_test_tmproot fm-inactive-reconcile)
fm_git_identity fmtest fmtest@example.invalid

set_mtime() { # <epoch> <path>
  local epoch=$1 path=$2 stamp
  if stamp=$(date -r "$epoch" +%Y%m%d%H%M.%S 2>/dev/null); then
    touch -t "$stamp" "$path"
  else
    stamp=$(date -d "@$epoch" +%Y%m%d%H%M.%S)
    touch -t "$stamp" "$path"
  fi
}

age() { # <path>...
  local path now
  now=$(( $(date +%s) - 120 ))
  for path in "$@"; do set_mtime "$now" "$path"; done
}

make_tools() { # <world>
  local world=$1 fake
  fake="$world/fakebin"
  mkdir -p "$fake"
  cat > "$fake/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf 'state: %s · source: fake\n' "${FM_FAKE_CREW_STATE:-unknown}"
SH
  cat > "$fake/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) printf '%%1\n' ;;
  capture-pane) printf 'idle\n> \n' ;;
esac
SH
  local tool
  for tool in gh gh-axi curl; do
    cat > "$fake/$tool" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$(basename "$0")" >> "${FM_FORGE_LOG:?}"
exit 97
SH
  done
  chmod +x "$fake"/*
}

make_world() { # <name>
  WORLD="$TMP_ROOT/$1"
  MAIN="$WORLD/main"
  MATE="$WORLD/mate"
  mkdir -p "$WORLD/root" "$MAIN"/{state,data,config,projects} "$MATE"/{state,data,config,projects,bin}
  : > "$MATE/AGENTS.md"
  make_tools "$WORLD"
  : > "$WORLD/forge.log"
}

bind_secondmate() { # <local|remote>
  local route=$1
  printf 'mate\n' > "$MATE/.fm-secondmate-home"
  if [ "$route" = local ]; then
    cat > "$MATE/.fm-secondmate-parent" <<EOF
schema=fm-secondmate-parent.v1
route=local
parent_home=$MAIN
EOF
  else
    cat > "$MATE/.fm-secondmate-parent" <<'EOF'
schema=fm-secondmate-parent.v1
route=remote
EOF
  fi
}

write_child() { # <home> <id> <status> [spawn-gen]
  local home=$1 id=$2 status=$3 spawn_gen=${4:-s${BASHPID:-$$}.$RANDOM} sha
  mkdir -p "$home/projects/$id"
  git -C "$home/projects/$id" init -q
  git -C "$home/projects/$id" commit -q --allow-empty -m init
  sha=$(git -C "$home/projects/$id" rev-parse HEAD)
  git -C "$home/projects/$id" update-ref refs/remotes/origin/main "$sha"
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=$home/projects/$id" \
    'harness=codex' 'kind=ship' 'mode=no-mistakes' 'yolo=off' \
    "spawn_gen=$spawn_gen" 'pr=https://example.test/owner/repo/pull/1' \
    "pr_head=$sha"
  printf '%s\n' "$status" > "$home/state/$id.status"
  : > "$home/state/$id.turn-ended"
  age "$home/state/$id.meta" "$home/state/$id.status" "$home/state/$id.turn-ended"
}

write_mate_meta() {
  fm_write_secondmate_meta "$MAIN/state/mate.meta" "$MATE"
  printf 'working: delegated scope\n' > "$MAIN/state/mate.status"
  age "$MAIN/state/mate.meta" "$MAIN/state/mate.status"
}

run_reconcile() { # <home> [--startup]
  local home=$1 option=${2:-}
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" scan ${option:+"$option"}
}

# The teardown-side entry point: deliver one child's terminal ledger line for a
# caller holding its meta lock.
run_report() { # <home> <child>
  local home=$1 child=$2
  PATH="$WORLD/fakebin:$PATH" FM_ROOT_OVERRIDE="$WORLD/root" FM_HOME="$home" \
    FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" FM_CONFIG_OVERRIDE="$home/config" \
    FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" "$RECON" report "$child"
}

wake_count() { # <home> <key prefix>
  grep -c "$2" "$1/state/.wake-queue" 2>/dev/null || true
}

outcome_count() { # <home> <suffix>
  find "$1/state/terminal-outcomes" -type f -name "*.$2" 2>/dev/null | wc -l | tr -d ' '
}

reported_outcome_key() { # <home> <id> <state>
  local home=$1 id=$2 state=$3 record key
  for record in "$home/state/terminal-outcomes"/*.reported; do
    [ -f "$record" ] || continue
    grep -Fxq "task_id=$id" "$record" || continue
    grep -Fxq "state=$state" "$record" || continue
    key=$(sed -n 's/^outcome_key=//p' "$record")
    case "$key" in
      "child-outcome-$id-$state-"[0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f][0-9a-f]) printf '%s\n' "$key"; return 0 ;;
    esac
  done
  return 1
}

prime_seen() { # <state> <status>
  FM_STATE_OVERRIDE="$1" bash -c '
    . "$1"
    fm_wake_status_mark_current "$2" "$3"
  ' _ "$ROOT/bin/fm-wake-lib.sh" "$1" "$2"
}

reap() { kill "$1" 2>/dev/null || true; wait "$1" 2>/dev/null || true; }

# The main retains a terminal presentation receipt until the corresponding wake
# is handled and acknowledged.
test_main_direct_terminal_presentation_receipt() {
  local err seq generation
  make_world main-direct; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "main did not queue terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "main did not retain presentation receipt"

  err="$WORLD/drain.err"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] || fail "main presentation did not require durable acknowledgement"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "acknowledged presentation did not receive its own receipt"
  pass "main direct terminal presentation has a durable receipt"
}

# Away-posture regression: a branch-actor drain that consumes an
# inactive-outcome check row must retire its terminal-outcome receipt exactly
# like a main ack does. The 2026-09-25 away window on the supervision host
# consumed the queue row but left the .pending receipt, so every later cadence
# scan republished the same fingerprint - the 1,734-escalation flood.
test_branch_ack_retires_inactive_outcome_receipt() {
  local err seq generation
  make_world branch-ack
  write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "scan did not queue the terminal presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "scan did not retain a presentation receipt"

  # The same grant the branch dispatch publishes for this row in the away
  # posture (check rows become branch-eligible), with this test's own live
  # process as the recorded grant owner.
  seq=$(awk -F '\t' '$4 ~ /^inactive-outcome:/ { print $2 }' "$MAIN/state/.wake-queue" | tail -1)
  case "$seq" in ''|*[!0-9]*) fail "the queued inactive-outcome row had no sequence" ;; esac
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" activate "$$" branch-ack \
    || fail "branch owner activation failed"
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" "$GRANT" publish branch-ack "$seq" \
    || fail "branch grant publication failed"

  err="$WORLD/branch-drain.err"
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" >/dev/null 2> "$err"
  seq=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation .*/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$seq" ] && [ -n "$generation" ] \
    || { cat "$err"; fail "branch presentation did not require durable acknowledgement"; }
  FM_SUPERVISION_ACTOR=branch FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_CONFIG_OVERRIDE="$MAIN/config" "$DRAIN" --ack-through "$seq" --recovery-generation "$generation" \
    || fail "branch acknowledgement failed"

  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] || fail "branch acknowledgement left its check row queued"
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "branch acknowledgement left the terminal-outcome receipt pending"
  [ "$(outcome_count "$MAIN" presented)" = 1 ] || fail "branch acknowledgement never recorded the presentation receipt"

  # The flood's shape: with the receipt retired, later cadence scans must not
  # republish the same unchanged fingerprint.
  local cycle
  for cycle in 1 2 3; do
    age "$MAIN/state/.inactive-outcome-reconcile"
    FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN"
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 0 ] \
      || fail "unchanged inactive outcome re-queued on cadence scan $cycle after its branch acknowledgement"
  done
  pass "a branch-actor acknowledgement retires the inactive-outcome receipt and later scans stay quiet"
}

# An unpushed CI-ready ship done: is not a parent-facing ready signal. The
# ledger pass reads the child's line before any PR is recorded for it, so the
# gate tests the worker copy's HEAD.


# The ledger pass runs on every poll, so a ship done: already delivered does
# not pay for the git reachability check again.


# A secondmate delivers a child's terminal ledger line to the parent on the
# very next poll, from the ledger alone: no current-state read, no inactive
# cadence, and no line appended by the mate model. The delivery carries the
# child's note, recorded PR, delivery mode, and merge posture, happens once,
# and takes the outcome away from the inactive path so it is never reported
# twice.


# A terminal record written as a multi-line block belongs to the ledger path
# whether the block lands before or during the state read: it is delivered once,
# under the ledger's own outcome key, and the inactive fallback stays out of it.


# A child that dies mid-prose cannot hide an outcome its run already proves: an
# unterminated continuation line states no terminal event, so the inactive
# fallback still reports the attributed failure upward.


# A persistent child that keeps appending routine prose after one terminal
# outcome does not mint a fresh parent event per sentence: the inactive receipt
# identity binds the incarnation, task, terminal state, and PR only, never the
# child's last status line.
test_inactive_receipt_ignores_later_status_prose() {
  make_world prose-after-outcome
  write_child "$MAIN" child 'working: quiet since'
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "inactive fallback did not publish exactly once"
  printf 'working: tidying up after the run\n' >> "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  printf 'working: still tidying\n' >> "$MAIN/state/child.status"
  age "$MAIN/state/child.status"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "changed prose minted duplicate presentation"
  [ "$(outcome_count "$MAIN" pending)" = 1 ] || fail "changed prose created a second terminal receipt"
  pass "later status prose does not change inactive terminal receipt identity"
}

# A busy child cannot keep later ledger outcomes from being visited, and is
# retried on the next poll after its lifecycle lock becomes available.


# A scout's done line carries its report pointer, a failed line is delivered
# under the failed verb, and a later terminal line after recovery is a new
# delivery rather than a suppressed duplicate.


# A PR URL a worker only ever mentioned in prose is never claimed as the
# task's delivered PR: without a recorded PR, only a terminal line in the
# ready-signal shape carries one, and a scout never carries one at all.
test_pr_field_requires_recorded_pr_or_ready_signal_line() {
  local id row
  make_world pr-provenance
  for id in prose ready stamped placeholder; do
    write_child "$MAIN" "$id" 'done: PR https://example.test/other/repo/pull/33 checks green'
    awk '$0 !~ /^pr=/' "$MAIN/state/$id.meta" > "$MAIN/state/$id.meta.tmp"
    mv "$MAIN/state/$id.meta.tmp" "$MAIN/state/$id.meta"
  done
  write_child "$MAIN" recorded 'done: recorded delivery'
  write_child "$MAIN" lookout 'done: PR https://example.test/other/repo/pull/55'
  sed 's/^kind=ship$/kind=scout/' "$MAIN/state/lookout.meta" > "$MAIN/state/lookout.meta.tmp"
  mv "$MAIN/state/lookout.meta.tmp" "$MAIN/state/lookout.meta"
  age "$MAIN/state/"*.meta
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  for id in prose ready stamped placeholder lookout; do
    row=$(grep -F "child=$id " "$MAIN/state/.wake-queue")
    [ -n "$row" ] || fail "$id terminal announcement missing"
    assert_not_contains "$row" 'pr=' "$id announced an unrecorded or scout PR"
  done
  row=$(grep -F 'child=recorded ' "$MAIN/state/.wake-queue")
  assert_contains "$row" 'pr=https://example.test/owner/repo/pull/1' "recorded PR was lost"
  pass "terminal announcements carry recorded PRs and never synthesize prose or scout delivery claims"
}

# If a terminal ledger line lands while the authoritative state read is in
# flight, the ledger path remains the single owner on the next poll.


# A terminal append can land after the inactive path's final ledger read but
# before its already-selected outcome is observed on the next poll. The receipt
# store reconciles that ledger event with the fallback delivery, while a later
# same-state completion remains independently deliverable.


# An intervening progress line means the next terminal line is a new completion,
# not a late ledger rendering of the inactive fallback.


# Receipt identity covers the complete terminal ledger line even when the
# captain-facing rendering truncates two long notes to the same text.


# A line still being appended has no trailing newline yet and must wait.


# The remote route delivers the same line into this home's parent-replies
# input, once.


# A ship done: the gate accepted stays owed while its parent write is pending.
# Teardown removes the worktree before `report`, so the retry delivers that
# line instead of re-testing a copy that no longer exists.


# `report <child>` is the teardown-side delivery: it delivers or says nothing
# is owed with 0, and returns non-zero only when the channel cannot be written.


# Teardown calls report while holding the child's metadata lock. A concurrent
# scan may hold the scan lock while waiting for that metadata lock, so report
# must not wait for the scan lock in the opposite order.




# A present invalid identity marker cannot turn a secondmate home into a main
# home. The original child state remains available after the routing alarm.


# A remote child route writes the existing mirror input once even across restarts.


# Reusing a task id creates a separate receipt for the new spawned worker even
# when its terminal state and status text match the retired worker exactly.
test_reused_task_id_reports_each_incarnation() {
  make_world reused-id
  write_child "$MAIN" child 'working: quiet since' spawn-one
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  rm -f "$MAIN/state/child.meta" "$MAIN/state/child.status" "$MAIN/state/child.turn-ended"
  write_child "$MAIN" child 'working: quiet since' spawn-two
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 2 ] || fail "reused id collided with prior incarnation"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 2 ] || fail "reused id did not create independent presentation"
  pass "reused task ids retain per-incarnation terminal receipts"
}

# Legacy metadata has no generation, so its stable per-spawn temp root preserves
# the same receipt identity across supported atomic metadata rewrites.
test_legacy_metadata_rewrite_keeps_receipt_identity() {
  local meta tmp
  make_world legacy-rewrite
  write_child "$MAIN" child 'working: quiet since' spawn-old
  meta="$MAIN/state/child.meta"
  tmp="$MAIN/state/.child.meta.legacy"
  awk '$0 !~ /^spawn_gen=/' "$meta" > "$tmp"
  printf 'tasktmp=/tmp/fm-child\n' >> "$tmp"
  mv "$tmp" "$meta"
  age "$meta"

  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup
  awk '{ print }' "$meta" > "$tmp"
  mv "$tmp" "$meta"
  age "$meta"
  FM_FAKE_CREW_STATE='failed' run_reconcile "$MAIN" --startup

  [ "$(outcome_count "$MAIN" pending)" = 1 ] \
    || fail "legacy metadata rewrite changed the terminal receipt identity"
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] \
    || fail "legacy metadata rewrite duplicated the parent report"
  pass "legacy metadata rewrites preserve terminal receipt identity"
}

# Reconciliation snapshots terminal state and incarnation under the same task
# lifecycle lock used by relaunch metadata publication.
test_relaunch_cannot_replace_metadata_during_state_snapshot() {
  local recon_pid update_pid record i
  make_world relaunch-race
  write_child "$MAIN" child 'working: quiet since' spawn-old
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
: > "${FM_RACE_WORLD:?}/state-started"
while [ ! -e "$FM_RACE_WORLD/state-release" ]; do sleep 0.05; done
printf 'state: failed · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  FM_RACE_WORLD="$WORLD" run_reconcile "$MAIN" --startup &
  recon_pid=$!
  i=0
  while [ "$i" -lt 40 ] && [ ! -e "$WORLD/state-started" ]; do sleep 0.05; i=$((i + 1)); done
  [ -e "$WORLD/state-started" ] || fail "reconciliation did not begin its state snapshot"

  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    meta="$FM_STATE_OVERRIDE/child.meta"
    lock=$(fm_meta_lock_path "$meta")
    fm_lock_acquire_wait "$lock"
    awk '\''{ sub(/^spawn_gen=.*/, "spawn_gen=spawn-new"); print }'\'' "$meta" > "$meta.tmp"
    mv "$meta.tmp" "$meta"
    printf "working: replacement active\n" > "$FM_STATE_OVERRIDE/child.status"
    : > "$2/meta-updated"
    fm_lock_release "$lock"
  ' _ "$ROOT" "$WORLD" &
  update_pid=$!
  i=0
  while [ "$i" -lt 10 ] && [ ! -e "$WORLD/meta-updated" ]; do sleep 0.05; i=$((i + 1)); done
  : > "$WORLD/state-release"
  wait "$recon_pid" || fail "reconciliation failed during relaunch race"
  wait "$update_pid" || fail "metadata replacement failed during relaunch race"

  record=$(find "$MAIN/state/terminal-outcomes" -type f -name '*.pending' | head -1)
  [ -n "$record" ] || fail "terminal snapshot did not produce a receipt"
  grep -Fxq 'incarnation=spawn-old' "$record" \
    || fail "terminal result was attributed to replacement metadata"
  pass "relaunch cannot replace metadata during terminal snapshot"
}

# Heartbeat backoff state is deliberately irrelevant to the independent cadence.
test_heartbeat_cap_does_not_delay_reconciliation() {
  make_world heartbeat; write_child "$MAIN" child 'done: PR https://example.test/owner/repo/pull/1 checks green'
  printf '12\n' > "$MAIN/state/.heartbeat-streak"
  : > "$MAIN/state/.last-heartbeat"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] || fail "heartbeat cap suppressed inactive terminal reconciliation"
  pass "terminal reconciliation ignores heartbeat backoff state"
}

# Only authoritative terminal states qualify. A captain-held item is excluded too.
test_scan_marker_replaces_symlink_safely() {
  make_world marker; write_child "$MAIN" child 'done: green'
  printf 'preserve me\n' > "$MAIN/state/marker-target"
  ln -s marker-target "$MAIN/state/.inactive-outcome-reconcile"
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(cat "$MAIN/state/marker-target")" = 'preserve me' ] \
    || fail "scan marker symlink overwrote its target"
  [ ! -L "$MAIN/state/.inactive-outcome-reconcile" ] \
    || fail "scan marker remained a symlink"
  pass "scan marker replaces a symlink without overwriting its target"
}

test_nonterminal_and_captain_held_states_do_not_report() {
  local state
  for state in working paused parked unknown; do
    make_world "nonterminal-$state"; write_child "$MAIN" child 'working: still active'
    FM_FAKE_CREW_STATE="$state" run_reconcile "$MAIN" --startup
    [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "$state produced a terminal outcome"
  done
  make_world captain-held; write_child "$MAIN" child 'captain-held: awaiting captain'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ "$(outcome_count "$MAIN" pending)" = 0 ] || fail "captain-held item was reconciled"
  pass "nonterminal and captain-held workers remain outside inactive terminal reporting"
}

# The actual watcher poll invokes the helper, while an idle secondmate remains
# exempt from wedge escalation and emits no false wake.
test_watcher_hook_and_idle_secondmate_exemption() {
  local out pid i
  make_world watcher; write_child "$MAIN" child 'done: green'; prime_seen "$MAIN/state" "$MAIN/state/child.status"
  out="$WORLD/watch.out"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" \
    FM_INACTIVE_RECONCILE_SECS=60 FM_INACTIVE_CREW_STATE_BIN="$WORLD/fakebin/fm-crew-state.sh" \
    FM_FORGE_LOG="$WORLD/forge.log" FM_POLL=1 FM_SIGNAL_GRACE=1 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 \
    FM_FAKE_CREW_STATE='done' "$WATCH" > "$out" 2>&1 &
  pid=$!
  i=0
  while [ "$i" -lt 40 ]; do
    kill -0 "$pid" 2>/dev/null || break
    [ "$(wake_count "$MAIN" 'inactive-outcome:')" = 1 ] && break
    sleep 0.1
    i=$((i + 1))
  done
  wait "$pid" 2>/dev/null || true
  grep -Fq 'check: inactive-outcome' "$out" || fail "watcher did not surface its reconciliation result"

  make_world idle-secondmate; bind_secondmate local; write_mate_meta; prime_seen "$MAIN/state" "$MAIN/state/mate.status"
  PATH="$WORLD/fakebin:$PATH" FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 "$WATCH" > "$WORLD/idle.out" 2>&1 &
  pid=$!; sleep 2; kill -0 "$pid" 2>/dev/null || fail "idle secondmate watcher exited unexpectedly"; reap "$pid"
  grep -F 'stale:' "$WORLD/idle.out" >/dev/null && fail "idle secondmate was treated as a wedge"
  [ ! -s "$MAIN/state/.wake-queue" ] || fail "idle secondmate emitted a false wake"
  pass "watcher hook wakes for terminal loss and preserves idle secondmate exemption"
}

# The real watcher poll in a secondmate home delivers a child's terminal ledger
# line to the parent channel on its first cycle, with no line appended by the
# mate and no wake needed in the mate home for it.


# A stalled authoritative state read consumes only the aggregate scan budget.
# The durable scan position lets the next invocation reach the following child.
test_stalled_state_read_is_bounded_and_scan_progresses() {
  local started elapsed
  make_world bounded
  write_child "$MAIN" a 'working: state read will stall'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
if [ "$1" = a ]; then
  sleep 30
else
  printf 'state: done · source: fake\n'
fi
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -le 3 ] || fail "stalled state read exceeded aggregate scan budget (${elapsed}s)"

  write_child "$MAIN" b 'done: green'
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 run_reconcile "$MAIN" --startup
  grep -Fq 'child=b state=done' "$MAIN/state/.wake-queue" \
    || fail "next bounded scan did not resume with the following child"
  pass "stalled state reads are bounded without starving later children"
}

test_full_scan_budget_includes_wake_lock_wait() {
  local holder started elapsed i
  make_world wake-lock; write_child "$MAIN" child 'done: green'
  FM_HOME="$MAIN" FM_STATE_OVERRIDE="$MAIN/state" bash -c '
    . "$1/bin/fm-wake-lib.sh"
    fm_lock_acquire_wait "$FM_WAKE_QUEUE_LOCK"
    : > "$2"
    sleep 30
  ' _ "$ROOT" "$WORLD/lock-ready" &
  holder=$!
  i=0
  while [ "$i" -lt 30 ] && [ ! -e "$WORLD/lock-ready" ]; do sleep 0.1; i=$((i + 1)); done
  [ -e "$WORLD/lock-ready" ] || fail "wake lock holder did not start"

  started=$(date +%s)
  FM_INACTIVE_RECONCILE_BUDGET_SECS=1 FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  elapsed=$(( $(date +%s) - started ))
  reap "$holder"
  # The unbounded wake-lock wait is ended by the process-group backstop, which
  # fires one second after the budget; the bound proves the scan cannot ride
  # the 30-second lock hold.
  [ "$elapsed" -le 4 ] || fail "wake lock wait exceeded aggregate scan budget (${elapsed}s)"
  pass "aggregate scan budget includes durable wake operations"
}

# A secondmate home seeded without its parent binding cannot report ANY terminal
# outcome upward, and every later one fails for the same reason. The diagnostic
# has to name the binding, or three weeks of identical failures read as three
# weeks of unrelated report failures.



# Forge command shims fail loudly. A successful scan proves this path never uses
# them while reconciling a local terminal outcome.
test_reconciliation_never_calls_forge() {
  make_world forge; write_child "$MAIN" child 'done: green'
  FM_FAKE_CREW_STATE='done' run_reconcile "$MAIN" --startup
  [ ! -s "$WORLD/forge.log" ] || fail "reconciliation invoked a forge command: $(cat "$WORLD/forge.log")"
  pass "reconciliation makes zero forge or PR API calls"
}

test_reconciliation_sets_no_forge_mode_for_state_read() {
  make_world no-forge-env; write_child "$MAIN" child 'working: quiet since'
  cat > "$WORLD/fakebin/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "${FM_CREW_STATE_NO_FORGE:-}" > "${FM_NO_FORGE_LOG:?}"
printf 'state: done · source: fake\n'
SH
  chmod +x "$WORLD/fakebin/fm-crew-state.sh"
  export FM_NO_FORGE_LOG="$WORLD/no-forge.log"
  run_reconcile "$MAIN" --startup
  unset FM_NO_FORGE_LOG
  assert_grep '1' "$WORLD/no-forge.log" "inactive reconciliation did not set crew-state no-forge mode"
  pass "reconciliation state reads set no-forge mode"
}

test_main_direct_terminal_presentation_receipt
test_branch_ack_retires_inactive_outcome_receipt
test_inactive_receipt_ignores_later_status_prose
test_pr_field_requires_recorded_pr_or_ready_signal_line
test_reused_task_id_reports_each_incarnation
test_legacy_metadata_rewrite_keeps_receipt_identity
test_relaunch_cannot_replace_metadata_during_state_snapshot
test_heartbeat_cap_does_not_delay_reconciliation
test_scan_marker_replaces_symlink_safely
test_nonterminal_and_captain_held_states_do_not_report
test_watcher_hook_and_idle_secondmate_exemption
test_stalled_state_read_is_bounded_and_scan_progresses
test_full_scan_budget_includes_wake_lock_wait
test_reconciliation_never_calls_forge
test_reconciliation_sets_no_forge_mode_for_state_read

echo "all inactive reconciliation tests passed"
