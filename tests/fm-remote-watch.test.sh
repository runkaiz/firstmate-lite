#!/usr/bin/env bash
# The supervision loop's remote-worker outage policy (docs/remote-workers.md),
# through the real loop executable: while a remote machine's link record is not
# reachable, its task gets no stale, transition, or inbox notification and its
# pane is never touched; one check notification fires after the grace period
# and one when the machine is reachable again; a courier finding fires once.
set -u

. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"

WATCH="$ROOT/bin/fm-watch.sh"
DRAIN="$ROOT/bin/fm-wake-drain.sh"
TMP_ROOT=$(fm_test_tmproot fm-remote-watch)
MID=0123456789abcdef0123456789abcdef
STATE="$TMP_ROOT/state"
FAKEBIN="$TMP_ROOT/fakebin"
mkdir -p "$STATE" "$FAKEBIN" "$TMP_ROOT/config" "$TMP_ROOT/wt"

# Any remote pane access during an outage is a failure the log exposes.
cat > "$FAKEBIN/herdr" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$TMP_ROOT/herdr.log"
exit 1
SH
cat > "$FAKEBIN/fm-crew-state.sh" <<'SH'
#!/usr/bin/env bash
echo 'state: unknown · source: remote-endpoint · machine unreachable'
SH
chmod +x "$FAKEBIN/herdr" "$FAKEBIN/fm-crew-state.sh"

printf 'window=%s:w2:p1\nendpoint_task_id=rt\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nharness=claude\nbackend=herdr-remote\nmachine_id=%s\nmachine_label=pegasus\nherdr_workspace_id=w2\nherdr_tab_id=w2:t1\nherdr_pane_id=w2:p1\nspawn_gen=s1\n' \
  "$MID" "$TMP_ROOT/wt" "$TMP_ROOT/wt" "$MID" > "$STATE/rt.meta"
link() {  # <state> <since>
  printf 'state=%s\nsince=%s\nreason=test\n' "$1" "$2" > "$STATE/.remote-link-$MID"
}

ack_stopped_cycle() {
  local err="$STATE/.test-cycle-drain.err" sequence generation
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" >/dev/null 2> "$err" || return 1
  sequence=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9][0-9]*\) --recovery-generation [A-Za-z0-9._-][A-Za-z0-9._-]*$/\1/p' "$err")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through [0-9][0-9]* --recovery-generation \([A-Za-z0-9._-][A-Za-z0-9._-]*\)$/\1/p' "$err")
  [ -n "$sequence" ] && [ -n "$generation" ] || return 1
  FM_STATE_OVERRIDE="$STATE" "$DRAIN" --ack-through "$sequence" --recovery-generation "$generation" >/dev/null 2>&1
}

run_watch() {  # <out> <timeout-ticks>
  PATH="$FAKEBIN:$PATH" FM_STATE_OVERRIDE="$STATE" FM_CONFIG_OVERRIDE="$TMP_ROOT/config" \
    FM_CREW_STATE_BIN="$FAKEBIN/fm-crew-state.sh" FM_POLL=1 FM_SIGNAL_GRACE=1 \
    FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999 FM_SECONDMATE_LIVENESS_SECS=99999999 \
    FM_REMOTE_SYNC_SECS=999999 FM_REMOTE_DOWN_GRACE_SECS=4 "$WATCH" > "$1" &
  WPID=$!
  wait_for_exit "$WPID" "$2"
}

# Down since now: the first passes stay silent and never touch the pane.
touch "$STATE/.remote-sync-$MID.last"
link unreachable "$(date +%s)"
run_watch "$TMP_ROOT/w1.out" 150
grep -q '^check: remote machine pegasus has been unreachable' "$TMP_ROOT/w1.out" \
  || fail "no grace-period check notification for an unreachable machine: $(cat "$TMP_ROOT/w1.out")"
! grep -q '^stale:' "$TMP_ROOT/w1.out" || fail 'an unreachable remote task raised a stale notification'
[ ! -s "$TMP_ROOT/herdr.log" ] || fail "the loop touched the remote pane during an outage: $(cat "$TMP_ROOT/herdr.log")"
[ -e "$STATE/.remote-link-$MID.alerted" ] || fail 'the outage notification was not recorded once'
ack_stopped_cycle || fail 'the outage notification could not be acknowledged'
pass 'an unreachable machine stays silent until one grace-period check notification, never touching the pane'

# Still down: no second outage notification; a courier finding fires once.
printf 'commit import failed for fm/rt\n' > "$STATE/rt.remote-alert"
run_watch "$TMP_ROOT/w2.out" 100
grep -q '^check: remote task rt: commit import failed' "$TMP_ROOT/w2.out" || fail "a courier finding did not surface: $(cat "$TMP_ROOT/w2.out")"
! grep -q 'has been unreachable' "$TMP_ROOT/w2.out" || fail 'the outage notification repeated'
ack_stopped_cycle || fail 'the finding notification could not be acknowledged'
pass 'a courier finding surfaces once and the outage notification does not repeat'

# Back: one return notification.
link reachable "$(date +%s)"
run_watch "$TMP_ROOT/w3.out" 100
grep -q '^check: remote machine pegasus is reachable again' "$TMP_ROOT/w3.out" || fail "no return notification: $(cat "$TMP_ROOT/w3.out")"
[ ! -e "$STATE/.remote-link-$MID.alerted" ] || fail 'the outage record survived the return'
ack_stopped_cycle || true
pass 'a returning machine raises one reachable-again notification'
