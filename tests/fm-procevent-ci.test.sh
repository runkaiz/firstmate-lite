#!/usr/bin/env bash
# Deterministic CI-only handoff tests: no live forge, daemon or model calls.
set -eu
# shellcheck source=tests/wake-helpers.sh
. "$(dirname "${BASH_SOURCE[0]}")/wake-helpers.sh"
LAB=$(fm_test_tmproot fm-procevent-ci)
cleanup_ci_test() {
  local test_state
  for test_state in "$LAB/home/state" "${state:-$LAB/unused-state}"; do
    if [ -f "$test_state/procevent/ci-run1.source" ]; then
      FM_STATE_OVERRIDE="$test_state" "$ROOT/bin/fm-procevent.sh" retire ci-run1 >/dev/null 2>&1 || true
    fi
  done
  fm_test_cleanup
}
trap cleanup_ci_test EXIT
mkdir -p "$LAB/fakebin" "$LAB/wt" "$LAB/home/state" "$LAB/home/config"
fm_git_identity ci-test ci-test@example.invalid
git -C "$LAB/wt" init -q
git -C "$LAB/wt" checkout -q -b fm/ci
git -C "$LAB/wt" commit -qm init --allow-empty
export CI_TEST_HEAD
CI_TEST_HEAD=$(git -C "$LAB/wt" rev-parse HEAD)
export CI_TEST_LAB=$LAB
export PATH="$LAB/fakebin:$PATH"
export FM_HOME="$LAB/home" FM_ROOT_OVERRIDE="$ROOT" FM_STATE_OVERRIDE="$LAB/home/state"
export FM_PROCEVENT_CLAIM_ROOT="$LAB/claims"
export CI_SCENARIO=pending CI_AFTER=5
printf 'kind=ship\nmode=no-mistakes\nworktree=%s\n' "$LAB/wt" > "$FM_STATE_OVERRIDE/task.meta"
chmod 600 "$FM_STATE_OVERRIDE/task.meta"
cat > "$LAB/fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
set -eu
count=0
[ ! -f "$CI_TEST_LAB/drives" ] || read -r count < "$CI_TEST_LAB/drives"
if [ "$*" = 'axi status' ]; then
  run=RUN1 branch=fm/ci state=running ci=running review=completed
  case "$CI_SCENARIO" in
    other-run) run=RUN2 ;;
    other-branch) branch=fm/other ;;
    revalidate) if [ "$count" -gt 0 ] && [ "$count" -lt 3 ]; then review=running; ci=pending; fi ;;
    repairing) state=fixing ;;
    missing-required) : ;;
    changed-head|post-return-rebase) if [ "$count" -gt 0 ]; then CI_TEST_HEAD=1111111111111111111111111111111111111111; fi ;;
    broken) exit 1 ;;
  esac
  printf 'run:\n  id: %s\n  branch: %s\n  status: %s\n  head_sha: %s\n  pr: https://github.com/example/repo/pull/1\n' "$run" "$branch" "$state" "$CI_TEST_HEAD"
  printf '  steps[9]{step,status,findings,duration_ms}:\n'
  for step in intent rebase review test document lint push pr ci; do
    status=completed
    [ "$step" != ci ] || status=$ci
    [ "$step" != review ] || status=$review
    printf '    %s,%s,0,0\n' "$step" "$status"
  done
  exit 0
fi
if [ "$*" = 'axi run --wait 1s' ]; then
  drive_identity() {
    printf 'run:\n  id: RUN1\n  branch: fm/ci\n  status: running\n  head_sha: %s\n  pr: https://github.com/example/repo/pull/1\n' "$CI_TEST_HEAD"
  }
  count=$((count+1)); printf '%s\n' "$count" > "$CI_TEST_LAB/drives"
  if [ "$CI_SCENARIO" = hold ]; then
    if [ -f "$CI_TEST_LAB/release" ]; then drive_identity; printf 'outcome: checks-passed\n'; else printf 'run:\n  status: running\n'; fi
    exit 0
  fi
  if [ "$count" -lt "$CI_AFTER" ]; then
    # Version-matched emitAxiWaitElapsed contract, including its nonzero exit.
    printf 'error: wait of 1s elapsed while driving the run\nhelp[1]:\n  This bounded hold ended; it is not a pipeline failure and does not mean the daemon is dead.\n'
    exit 1
  fi
  case "$CI_SCENARIO" in error|near-elapsed) ;; *) drive_identity ;; esac
  case "$CI_SCENARIO" in
    gate|revalidate) printf 'gate: ci\nfindings[1]{id,severity,file,line,action,description}:\n  c1,error,file,1,ask-user,CI failed; approval required\n' ;;
    failed) printf 'outcome: failed\nerror: checks failed\n'; exit 1 ;;
    error) printf 'error: daemon socket refused\n'; exit 1 ;;
    near-elapsed) printf 'error: wait of 1s elapsed while driving the run; daemon unconfirmed\n'; exit 1 ;;
    skips) printf 'outcome: passed-with-skips\n' ;;
    missing-required) printf 'gate: ci\nerror: required check has not reported\n' ;;
    *) printf 'outcome: checks-passed\n' ;;
  esac
  exit 0
fi
printf 'unexpected no-mistakes command: %s\n' "$*" >&2
exit 99
SH
cat > "$LAB/fakebin/gh" <<'SH'
#!/usr/bin/env bash
set -eu
printf '%s\n' "$*" >> "$CI_TEST_LAB/forge-calls"
[ "$*" = 'pr view https://github.com/example/repo/pull/1 --json url,headRefOid --jq [.url,.headRefOid] | @tsv' ] || exit 99
head=$CI_TEST_HEAD
case "$CI_SCENARIO" in stale-green|post-return-rebase) head=1111111111111111111111111111111111111111 ;; esac
printf 'https://github.com/example/repo/pull/1\t%s\n' "$head"
SH
cat > "$LAB/fakebin/sleep" <<'SH'
#!/usr/bin/env bash
set -eu
if [ "$1" = 30 ]; then
  clock=0
  [ ! -f "$CI_TEST_LAB/clock" ] || read -r clock < "$CI_TEST_LAB/clock"
  printf '%s\n' "$((clock+30))" > "$CI_TEST_LAB/clock"
  if [ "$CI_SCENARIO" = hold ]; then /bin/sleep .05; fi
  exit 0
fi
exec /bin/sleep "$@"
SH
# Any accidental model/backend dispatch in this exercised path is observable.
for model in codex pi claude tmux herdr; do
  cat > "$LAB/fakebin/$model" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$0 $*" >> "$CI_TEST_LAB/model-dispatches"
exit 99
SH
done
chmod +x "$LAB/fakebin/"*
ADAPTER="$ROOT/bin/fm-procevent-ci.sh"
PR=https://github.com/example/repo/pull/1
poll() { "$ADAPTER" poll task "$LAB/wt" RUN1 fm/ci "$PR"; }
reset_counts() { rm -f "$LAB/drives" "$LAB/clock" "$LAB/forge-calls"; }
check() { local name=$1; shift; if ! "$@"; then printf 'FAIL: %s\n' "$name" >&2; exit 1; fi; printf 'PASS: %s\n' "$name"; }
contains() { [[ "$1" == *"$2"* ]]; }
not_waiting() { ! fm_procevent_ci_waiting "$@"; }
line_count() { wc -l < "$1" | tr -d ' '; }

out=$(poll)
check 'four unchanged pending holds consumed in one shell before action' test "$(cat "$LAB/drives")" = 5
check 'controlled clock advances without real CI wait' test "$(cat "$LAB/clock")" = 120
check 'zero worker/supervisor model dispatches during pending holds' test ! -e "$LAB/model-dispatches"
check 'only pipeline drive supplies green evidence' contains "$out" "outcome: checks-passed"
check 'forge verification only at actionable green return' test "$(line_count "$LAB/forge-calls")" = 1

for scenario in gate failed error near-elapsed stale-green skips revalidate other-run other-branch broken missing-required changed-head post-return-rebase; do
  reset_counts; export CI_SCENARIO=$scenario CI_AFTER=1
  [ "$scenario" != revalidate ] || export CI_AFTER=3
  out=$(poll)
  case "$scenario" in
    gate) check 'approval finding preserved verbatim' contains "$out" "ask-user,CI failed; approval required" ;;
    failed) check 'failure retained rather than hidden by wait' contains "$out" "outcome: failed" ;;
    error|near-elapsed|other-run|other-branch|broken) check "$scenario stops safely" contains "$out" "ci_wait: monitor-error" ;;
    stale-green) check 'new forge head cannot inherit stale green' contains "$out" "ci_wait: head-changed" ;;
    skips) check 'skipped CI remains explicit, never clean green' contains "$out" "outcome: passed-with-skips" ;;
    revalidate)
      check 'pipeline rebase/revalidation waits without worker observation turns' test "$(cat "$LAB/drives")" = 3
      check 'revalidation gate returns to original driver' contains "$out" 'gate: ci'
      ;;
    missing-required) check 'missing required checks remain visible through pipeline gate' contains "$out" "required check has not reported" ;;
    post-return-rebase) check 'matching new status and forge heads cannot launder an older drive green' contains "$out" 'ci_wait: head-changed' ;;
    changed-head) check 'pipeline head changes cannot inherit a prior forge head green' contains "$out" "ci_wait: head-changed" ;;
  esac
done

# Recovery through the real runner: a persisted registration with no listener
# is reconciled, pending holds publish nothing, one terminal capture wakes once,
# and handled + restart cannot wake a completed worker again.
reset_counts; export CI_SCENARIO=hold CI_AFTER=1
"$ROOT/bin/fm-procevent.sh" register ci ci-run1 -- "$ADAPTER" poll task "$LAB/wt" RUN1 fm/ci "$PR" >/dev/null
# shellcheck source=/dev/null
. "$ROOT/bin/fm-pr-lib.sh"
# shellcheck source=/dev/null
. "$ROOT/bin/fm-procevent-lib.sh"
check 'durable registration owns wait before listener recovery' fm_procevent_ci_waiting "$FM_STATE_OVERRIDE" task "$ROOT"
"$ROOT/bin/fm-procevent.sh" ensure-listening ci-run1 >/dev/null
check 'recovered pending listener emits zero supervisor dispatch events' test ! -s "$FM_STATE_OVERRIDE/.wake-queue"
check 'listener recovery dispatches no models' test ! -e "$LAB/model-dispatches"
# The poll is blocked on a fixture clock event; advance it once into green.
touch "$LAB/release"
# Waiting on a real process-event write, with a bounded fixture-only deadline.
for ((i=0; i<200; i++)); do
  results=("$FM_STATE_OVERRIDE/procevent-inbox/ci-run1."*.result)
  [ -f "${results[0]}" ] && [ -s "$FM_STATE_OVERRIDE/.wake-queue" ] && break
  /bin/sleep .05
done
check 'action captured durably and queued' test -f "${results[0]}"
check 'one actionable transition produces one queued wake' test "$(line_count "$FM_STATE_OVERRIDE/.wake-queue")" = 1
result_file=${results[0]}
check 'capture classified by owning adapter' test "$("$ADAPTER" classify "$result_file")" = action
seq=${result_file##*/ci-run1.}; seq=${seq%.result}
"$ROOT/bin/fm-procevent.sh" handled ci-run1 "$seq" >/dev/null
before=$(wc -l < "$FM_STATE_OVERRIDE/.wake-queue" | tr -d ' ')
"$ROOT/bin/fm-procevent.sh" reconcile >/dev/null
check 'handled action not reannounced after reconcile/restart' test "$(line_count "$FM_STATE_OVERRIDE/.wake-queue")" = "$before"
check 'terminal wait retires so it cannot wake completed worker again' not_waiting "$FM_STATE_OVERRIDE" task "$ROOT"
check 'entire exercised monitor path dispatches zero models' test ! -e "$LAB/model-dispatches"
# Public handoff verifies eligibility and exclusive ownership before parking.
reset_counts; rm -f "$LAB/release"
export CI_SCENARIO=repairing
if "$ADAPTER" arm task > "$LAB/arm.out" 2>&1; then exit 1; fi
check 'public arm refuses repair without registering a wait' test ! -e "$FM_STATE_OVERRIDE/procevent/ci-run1.source"
export CI_SCENARIO=hold
: > "$FM_STATE_OVERRIDE/task.check.sh"
if "$ADAPTER" arm task > "$LAB/arm.out" 2>&1; then exit 1; fi
check 'public arm refuses a duplicate PR monitor' test ! -e "$FM_STATE_OVERRIDE/procevent/ci-run1.source"
rm "$FM_STATE_OVERRIDE/task.check.sh"
"$ADAPTER" arm task > "$LAB/arm.out"
check 'public arm confirms durable CI listener' fm_procevent_ci_waiting "$FM_STATE_OVERRIDE" task "$ROOT"
if "$ADAPTER" arm task > "$LAB/duplicate.out" 2>&1; then exit 1; fi
check 'repeated handoff cannot replace existing owner' grep -q "already registered" "$LAB/duplicate.out"
if "$ROOT/bin/fm-pr-check.sh" task "$PR" > "$LAB/merge.out" 2>&1; then exit 1; fi
check 'merge monitor refuses overlapping CI custody' grep -q "delegated CI wait" "$LAB/merge.out"
"$ROOT/bin/fm-procevent.sh" retire ci-run1 >/dev/null
if FM_PROCEVENT_LAUNCH_CONFIRM_SECONDS=invalid "$ADAPTER" arm task > "$LAB/failed-arm.out" 2>&1; then exit 1; fi
check 'unconfirmed handoff retires its registration before driver resumes' test ! -e "$FM_STATE_OVERRIDE/procevent/ci-run1.source"
check 'failed confirmation explicitly returns drive ownership' grep -q 'registration retired, retain drive ownership' "$LAB/failed-arm.out"
# Exercise the real watcher stale path with a live registered wait. The task
# pane is deliberately idle and its declared pause is overdue; without the
# registration the same fixture must surface, making silence non-vacuous.
TMP_ROOT="$LAB/watch-cases"
case_dir=$(make_case ci-watch)
state="$case_dir/state"
export FM_STATE_OVERRIDE=$state
printf 'kind=ship\nmode=no-mistakes\nbackend=tmux\nharness=grok\nwindow=test:fm-task\nworktree=%s\n' "$LAB/wt" > "$state/task.meta"
chmod 600 "$state/task.meta"
printf 'paused: CI wait delegated\n' > "$state/task.status"
prime_status_seen "$state" "$state/task.status"
printf 'idle prompt\n' > "$case_dir/pane"
PATH="$case_dir/fakebin:$PATH" "$ADAPTER" arm task > "$case_dir/arm.out"
PATH="$case_dir/fakebin:$PATH" FM_FAKE_TMUX_WINDOW=test:fm-task \
  FM_FAKE_TMUX_CAPTURE="$case_dir/pane" FM_FAKE_TMUX_CURRENT_COMMAND=grok \
  FM_FAKE_TMUX_CAPTURE_COUNT_FILE="$case_dir/captures" \
  FM_FAKE_CREW_STATE='state: paused · source: status-log · CI wait delegated' \
  FM_CREW_STATE_BIN="$case_dir/fakebin/fm-crew-state.sh" \
  FM_WATCH_HANDLING_SUCCESSOR=1 FM_PAUSE_RESURFACE_SECS=1 \
  FM_POLL=1 FM_SIGNAL_GRACE=0 FM_CHECK_INTERVAL=999999 FM_HEARTBEAT=1 \
  "$ROOT/bin/fm-watch.sh" > "$case_dir/watch.out" 2>&1 &
watch_pid=$!
# Observe three whole poll cycles using the beacon's actual updates.
file_mtime() {
  if [ "$(uname)" = Darwin ]; then stat -f %m "$1" 2>/dev/null || true
  else stat -c %Y "$1" 2>/dev/null || true; fi
}
last=none; cycles=0
for ((i=0; i<200; i++)); do
  current=$(file_mtime "$state/.last-watcher-beat")
  if [ -n "$current" ] && [ "$current" != "$last" ]; then cycles=$((cycles+1)); last=$current; fi
  [ "$cycles" -ge 4 ] && break
  /bin/sleep .05
done
check 'real watcher completes repeated pending cycles' test "$cycles" -ge 4
check 'unchanged CI produces zero pane-review/heartbeat dispatch events' test ! -s "$state/.wake-queue"
check 'CI-owned task is never pane-captured for stale review' test ! -e "$case_dir/captures"
"$ROOT/bin/fm-procevent.sh" retire ci-run1 >/dev/null
# Losing the durable owner restores the ordinary safety backstop.
wait_for_exit "$watch_pid" 100 || { kill "$watch_pid" 2>/dev/null || true; exit 1; }
check 'without CI ownership same idle worker becomes actionable' grep -q 'stale:' "$case_dir/watch.out"
# Execute the handoff command emitted to a worker, rather than only looking
# for prose. Both config postures use the same supported command.
for posture in ordinary wait-no-turns; do
  genhome="$LAB/generated-$posture"
  mkdir -p "$genhome/state" "$genhome/config"
  [ "$posture" != wait-no-turns ] || touch "$genhome/config/wait-no-turns"
  FM_HOME="$genhome" FM_STATE_OVERRIDE="$genhome/state" \
    "$ROOT/bin/fm-brief.sh" task example --mode no-mistakes >/dev/null
  cp "$LAB/home/state/task.meta" "$genhome/state/task.meta"
  # shellcheck disable=SC2016 # Extract the literal backtick-delimited command from the generated interface.
  command=$(sed -n 's/^When only CI remains running.*using `\(.*\)`\.$/\1/p' "$genhome/data/task/brief.md")
  check 'generated handoff command is present in either wait configuration' test -n "$command"
  bash -c "$command" > "$genhome/arm.out"
  check 'generated worker command confirms actual listener in either posture' fm_procevent_ci_waiting "$genhome/state" task "$ROOT"
  FM_STATE_OVERRIDE="$genhome/state" "$ROOT/bin/fm-procevent.sh" retire ci-run1 >/dev/null
done
printf 'CI wait tests passed\n'
