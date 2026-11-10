#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/runkai/.no-mistakes/evidence/01M73R30H4BF6WJNPT335EKD5M
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_SUPERVISION_ACTOR
export TMPDIR="$ROOT/.gate-test-lab/tmp"
export FM_PROCEVENT_CLAIM_ROOT="$ROOT/.gate-test-lab/claims"
export XDG_STATE_HOME="$ROOT/.gate-test-lab/xdg-state"
export NM_HOME="$ROOT/.gate-test-lab/nm-empty"
export CODEX_HOME="$ROOT/.gate-test-lab/codex-empty"
export CLAUDE_CONFIG_DIR="$ROOT/.gate-test-lab/claude-empty"
export PI_CODING_AGENT_DIR="$ROOT/.gate-test-lab/pi-empty"
# No default tmux server is ever addressed. This private socket has no server:
# the lifecycle scenario starts with an already-exited worker endpoint.
export TMUX="$ROOT/.gate-test-lab/absent-socket,0,0"
export FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=999999
export FM_ARM_CONFIRM_TIMEOUT=30
LABS=()
ARMS=()
cleanup() {
  for h in "${LABS[@]}"; do
    FM_HOME="$h" "$ROOT/bin/fm-watch-arm.sh" --stop >/dev/null 2>&1 || true
    for s in "$h/state/procevent/"*.source; do
      [ -e "$s" ] || continue
      id=${s##*/}; id=${id%.source}
      FM_HOME="$h" "$ROOT/bin/fm-procevent.sh" retire "$id" >/dev/null 2>&1 || true
    done
  done
  for p in "${ARMS[@]}"; do wait "$p" 2>/dev/null || true; done
  rm -rf -- "$ROOT/.gate-test-lab/copies-retained"
  for h in "${LABS[@]}"; do rm -rf -- "$h"; done
}
trap cleanup EXIT
home() {
  local h="$ROOT/.gate-test-lab/$1"
  "$ROOT/bin/fm-lab-home.sh" create "$h"
  LABS+=("$h")
  printf 'off\n' > "$h/config/usage-ledger"
  printf 'manual\n' > "$h/config/backlog-backend"
  export FM_HOME=$h
}
await() {
  local i
  for ((i=0;i<400;i++)); do "$@" && return; sleep .05; done
  printf 'Timeout: %s\n' "$*" >&2; return 1
}
acked() { grep -q '^acked:downtime:' "$FM_HOME/state/.watcher-down" 2>/dev/null; }
nonempty() { [ -s "$1" ]; }
append() {
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append "$2" "$3" "$4"' _ "$ROOT" "$1" "$2" "$3"
}
publish_downtime() {
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" downtime' _ "$ROOT"
}

home quiet
{
  printf 'SCENARIO: empty monitoring recovery remains silent, then new work wakes it\n'
  publish_downtime
  "$ROOT/bin/fm-watch-arm.sh" --restart > "$FM_HOME/arm.out" 2> "$FM_HOME/arm.err" &
  arm=$!; ARMS+=("$arm")
  await acked
  sleep 3
  kill -0 "$arm"
  cat "$FM_HOME/state/.watcher-down" "$FM_HOME/arm.out"
  ! grep -Eq '^(check|signal|stale|heartbeat):' "$FM_HOME/arm.out"
  [ ! -s "$FM_HOME/state/.wake-queue" ]
  printf 'Observed: live monitoring remained active for three seconds, with no notification and no queued work.\n'
  append check inbox:lab-new 'check: lab actionable note after silent recovery'
  await nonempty "$FM_HOME/state/.wake-queue"
  wait "$arm"
  cat "$FM_HOME/arm.out"
  "$ROOT/bin/fm-wake-drain.sh" 2> "$FM_HOME/drain.err" | tee "$FM_HOME/drain.out"
  grep -Fq 'lab actionable note after silent recovery' "$FM_HOME/drain.out"
  printf 'Observed: the newly appended actionable note reached the drain.\n'
} > "$EVIDENCE/live-silent-recovery.log" 2>&1

home queued
{
  printf 'SCENARIO: queued work survives downtime and resurfaces on re-arm\n'
  append check inbox:lab-queued 'check: lab note queued while monitoring was down'
  publish_downtime
  "$ROOT/bin/fm-watch-arm.sh" --restart > "$FM_HOME/arm.out" 2> "$FM_HOME/arm.err" &
  arm=$!; ARMS+=("$arm")
  wait "$arm"
  cat "$FM_HOME/arm.out"
  "$ROOT/bin/fm-wake-drain.sh" 2> "$FM_HOME/drain.err" | tee "$FM_HOME/drain.out"
  grep -Fq 'lab note queued while monitoring was down' "$FM_HOME/drain.out"
  printf 'Observed: recovery presented the exact queued note.\n'
} > "$EVIDENCE/live-queued-recovery.log" 2>&1

home replay
{
  printf 'SCENARIO: a real captured result survives unhandled replay, then is suppressed for both actors once handled\n'
  "$ROOT/bin/fm-procevent.sh" register lavish lab-result -- /usr/bin/printf '%s\n' 'disposable lab result'
  "$ROOT/bin/fm-procevent.sh" ensure-listening lab-result
  await nonempty "$FM_HOME/state/.wake-queue"
  # Wait for this exact producer to release its claim after publication.
  await test ! -e "$FM_PROCEVENT_CLAIM_ROOT/lab-result.claim"
  "$ROOT/bin/fm-procevent.sh" retire lab-result
  cat "$FM_HOME/state/procevent-inbox/lab-result.1.result"
  mv "$FM_HOME/state/.wake-queue" "$FM_HOME/state/initial-queue"
  "$ROOT/bin/fm-procevent.sh" reconcile
  "$ROOT/bin/fm-wake-drain.sh" > "$FM_HOME/unhandled.out" 2> "$FM_HOME/unhandled.err"
  cat "$FM_HOME/unhandled.out"
  grep -Fq 'procevent lavish lab-result 1' "$FM_HOME/unhandled.out"
  cp "$FM_HOME/state/.wake-queue" "$FM_HOME/replay-queue"
  # Clear the presentation claim: the original main turn is now finishing.
  seq=$(cut -f2 "$FM_HOME/replay-queue")
  generation=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$FM_HOME/unhandled.err")
  "$ROOT/bin/fm-wake-drain.sh" --ack-through "$seq" --recovery-generation "$generation"
  "$ROOT/bin/fm-procevent.sh" handled lab-result 1
  "$ROOT/bin/fm-procevent.sh" handled lab-result 1
  for actor in branch main; do
    cp "$FM_HOME/replay-queue" "$FM_HOME/state/.wake-queue"
    # Additional rows use the same serialized queue contract, with distinct
    # sequence identities to exercise the branch grant boundary.
    printf '%s\t98\tcheck\tprocevent:lab-result:1\tcheck: main-owned handled replay\n' "$(date +%s)" >> "$FM_HOME/state/.wake-queue"
    printf '%s\t99\tcheck\tunrelated\tcheck: unrelated actionable note\n' "$(date +%s)" >> "$FM_HOME/state/.wake-queue"
    if [ "$actor" = branch ]; then
      "$ROOT/bin/fm-wake-grant.sh" activate "$$" live-replay
      "$ROOT/bin/fm-wake-grant.sh" publish live-replay "$seq" 99
    fi
    FM_SUPERVISION_ACTOR="$actor" "$ROOT/bin/fm-wake-drain.sh" > "$FM_HOME/$actor.out" 2> "$FM_HOME/$actor.err"
    printf '\nActor %s output:\n' "$actor"
    cat "$FM_HOME/$actor.out"
    ! grep -Fq 'lab-result' "$FM_HOME/$actor.out"
    ! grep -Fq PROCEVENT_HANDLED_REQUIRED "$FM_HOME/$actor.err"
    grep -Fq 'unrelated actionable note' "$FM_HOME/$actor.out"
    printf 'Queue after actor %s drain:\n' "$actor"
    cat "$FM_HOME/state/.wake-queue"
    ! awk -F '\t' -v n="$seq" '$2==n {found=1} END {exit !found}' "$FM_HOME/state/.wake-queue"
    if [ "$actor" = branch ]; then
      grep -Fq 'main-owned handled replay' "$FM_HOME/state/.wake-queue"
      "$ROOT/bin/fm-wake-grant.sh" deactivate "$$" live-replay
    else
      ! grep -Fq 'main-owned handled replay' "$FM_HOME/state/.wake-queue"
    fi
  done
  printf 'Observed: both actors suppressed handled results; branch preserved the main-owned replay and unrelated work remained visible.\n'
} > "$EVIDENCE/live-handled-replay.log" 2>&1

home retained
{
  printf 'SCENARIO: keep a completed branch during cleanup, then land it with the normal guards\n'
  PROJ="$FM_HOME/projects/demo"
  COPIES="$ROOT/.gate-test-lab/copies-retained"
  mkdir -p "$PROJ" "$COPIES"
  git -C "$PROJ" init -q -b main
  git -C "$PROJ" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial --allow-empty
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'git\n' > "$FM_HOME/config/worktree-allocator"
  printf '%s\n' "$COPIES" > "$FM_HOME/config/git-worktree-root"
  . "$ROOT/bin/fm-git-worktree-lib.sh"
  fm_git_worktree_allocate "$FM_HOME/state" retained-demo "$FM_HOME" "$PROJ" "$COPIES" "$BASE" refs/heads/main
  WT=$FM_GIT_WORKTREE_PATH
  git -C "$WT" switch -qc fm/retained-demo
  printf 'delivered locally\n' > "$WT/result.txt"
  git -C "$WT" add result.txt
  git -C "$WT" -c user.name=lab -c user.email=lab@example.invalid commit -qm delivery
  HEAD=$(git -C "$WT" rev-parse HEAD)
  printf 'window=fm-lab:fm-retained-demo\nendpoint_task_id=retained-demo\nbackend=tmux\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nbranch=fm/retained-demo\nspawn_gen=s1792922400.123.456\nallocator=git\n' "$WT" "$PROJ" > "$FM_HOME/state/retained-demo.meta"
  chmod 600 "$FM_HOME/state/retained-demo.meta"
  printf 'done: delivery ready\n' > "$FM_HOME/state/retained-demo.status"
  if "$ROOT/bin/fm-teardown.sh" retained-demo; then echo 'ERROR: unlanded work was discarded'; exit 1; fi
  [ -d "$WT" ] && [ -f "$FM_HOME/state/retained-demo.meta" ]
  "$ROOT/bin/fm-teardown.sh" retained-demo --retain-branch
  [ ! -e "$WT" ] && [ ! -e "$FM_HOME/state/retained-demo.meta" ]
  cat "$FM_HOME/state/retained-demo.retained"
  [ "$(git -C "$PROJ" rev-parse main)" = "$BASE" ]
  [ "$(git -C "$PROJ" rev-parse refs/firstmate/retained-work/retained-demo)" = "$HEAD" ]
  printf 'intentional dirty input\n' > "$PROJ/dirt"
  if "$ROOT/bin/fm-merge-local.sh" retained-demo; then echo 'ERROR: dirty main accepted'; exit 1; fi
  [ -f "$FM_HOME/state/retained-demo.retained" ]
  rm "$PROJ/dirt"
  "$ROOT/bin/fm-merge-local.sh" retained-demo
  [ "$(git -C "$PROJ" rev-parse main)" = "$HEAD" ]
  [ ! -e "$FM_HOME/state/retained-demo.retained" ]
  cat "$PROJ/result.txt"
  if "$ROOT/bin/fm-merge-local.sh" retained-demo; then echo 'ERROR: duplicate landing accepted'; exit 1; fi
  git -C "$PROJ" switch -qc fm/divergent "$BASE"
  printf 'divergent task\n' > "$PROJ/divergent.txt"
  git -C "$PROJ" add divergent.txt
  git -C "$PROJ" -c user.name=lab -c user.email=lab@example.invalid commit -qm divergent
  git -C "$PROJ" switch -q main
  printf 'project=%s\nmode=local-only\nbranch=fm/divergent\n' "$PROJ" > "$FM_HOME/state/divergent.retained"
  if "$ROOT/bin/fm-merge-local.sh" divergent; then echo 'ERROR: divergent branch accepted'; exit 1; fi
  [ -f "$FM_HOME/state/divergent.retained" ]
  [ "$(git -C "$PROJ" rev-parse main)" = "$HEAD" ]
  printf 'Observed: divergent retained branch refused without moving main or deleting its landing record.\n'
  printf 'Observed: cleanup retained the commit without landing it; dirty-main landing refused; clean landing fast-forwarded main; repeat landing refused.\n'
} > "$EVIDENCE/live-retained-landing.log" 2>&1
printf 'All disposable live CLI scenarios completed.\n'
