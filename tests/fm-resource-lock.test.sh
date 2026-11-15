#!/usr/bin/env bash
# Behavior tests for bin/fm-resource-lock.sh: the machine's declared resource
# locks, which let heavy commands serialize themselves instead of firstmate
# counting workers.
#
# Every case drives the real script against a private declaration and a private
# $XDG_RUNTIME_DIR. A limit is judged by what actually ran while a slot was
# held - a marker the wrapped command writes - never by wording alone, and
# holders are real flock(1) processes. Cases that take locks capability-skip
# where flock(1) is not installed; the declaration and brief cases still run.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LOCK="$ROOT/bin/fm-resource-lock.sh"
TMP_ROOT=$(fm_test_tmproot fm-resource-lock)
BASE_PATH=$PATH
HAVE_FLOCK=0
command -v flock >/dev/null 2>&1 && HAVE_FLOCK=1

# --- fixture ----------------------------------------------------------------

# A home with a declaration and its own runtime directory.
make_case() {  # <name> [declaration-line...]
  local case_dir="$TMP_ROOT/$1"
  shift
  mkdir -p "$case_dir/home/config" "$case_dir/run"
  [ $# -eq 0 ] || printf '%s\n' "$@" > "$case_dir/home/config/resource-locks"
  printf '%s\n' "$case_dir"
}

# Run the script for a case at a fixed local time, with a fast poll.
lock() {  # <case-dir> <HH:MM> <args...>
  local case_dir=$1 now=$2
  shift 2
  FM_ROOT_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_HOME="$case_dir/home" \
    XDG_RUNTIME_DIR="$case_dir/run" FM_RESOURCE_LOCK_NOW="$now" \
    FM_RESOURCE_LOCK_POLL_SECS=0.1 \
    "$LOCK" "$@"
}

# Wait, bounded, for a path to exist.
await_path() {  # <path> [tenths]
  local i=0 limit=${2:-150}
  while [ ! -e "$1" ]; do
    i=$((i + 1))
    [ "$i" -lt "$limit" ] || return 1
    sleep 0.1
  done
}

# Wait, bounded, for a fixed string to appear in a file.
await_text() {  # <file> <text>
  local i=0
  while ! grep -F -- "$2" "$1" >/dev/null 2>&1; do
    i=$((i + 1))
    [ "$i" -lt 150 ] || return 1
    sleep 0.1
  done
}

# Hold a lock file with plain flock(1), the way a job that knows nothing of
# this script does, until <tag>.release appears. It lets go by itself after a
# bound so a failed case can never leave a holder behind.
hold_file() {  # <lock-file> <tag>
  # shellcheck disable=SC2016 # The holder expands its own arguments.
  flock "$1" sh -c '
    : > "$1.held"
    i=0
    while [ ! -e "$1.release" ] && [ "$i" -lt 300 ]; do
      i=$((i + 1))
      sleep 0.1
    done
  ' holder "$2" &
  await_path "$2.held" || fail "the plain flock holder for $1 never started"
}

# Start a wrapped command in the background; it writes <tag>.ran when it runs.
# The script itself is the background process, so $! can stop a job that would
# otherwise wait forever.
start_job() {  # <case-dir> <HH:MM> <resource> <tag>
  # shellcheck disable=SC2016 # The wrapped command expands its own argument.
  FM_ROOT_OVERRIDE='' FM_CONFIG_OVERRIDE='' FM_HOME="$1/home" \
    XDG_RUNTIME_DIR="$1/run" FM_RESOURCE_LOCK_NOW="$2" FM_RESOURCE_LOCK_POLL_SECS=0.1 \
    "$LOCK" run "$3" -- sh -c ': > "$1.ran"' job "$4" 2> "$4.err" &
}

# --- declaration ------------------------------------------------------------

test_declaration_renders_resources_and_windows() {
  local case_dir out
  case_dir=$(make_case declared \
    '# heavy suite: two by day, one overnight' \
    '' \
    'suite 2 22:00-09:00=1 full test-suite runs' \
    'gpu 1 any GPU use' \
    'build 3 12:00-13:00=1 13:00-14:00=5   lunchtime   builds')
  out=$(lock "$case_dir" 12:30 brief) || fail "brief refused a valid declaration: $out"
  assert_contains "$out" '2 at once, 1 during 22:00-09:00' "the overnight window was not rendered"
  assert_contains "$out" '1 at once) - any GPU use' "a one-slot resource was not rendered"
  assert_contains "$out" '3 at once, 1 during 12:00-13:00, 5 during 13:00-14:00' "multiple windows were not rendered"
  assert_contains "$out" '- lunchtime   builds' "the description was not kept as written"
  pass "brief renders declared resources, multiple windows, and descriptions"
}

test_absent_declaration_declares_nothing() {
  local case_dir out rc=0
  case_dir=$(make_case absent)
  out=$(lock "$case_dir" 12:00 brief 2>&1) || rc=$?
  expect_code 0 "$rc" "brief failed without a declaration: $out"
  assert_equals "" "$out" "an absent declaration added a brief section"
  pass "an absent declaration declares nothing and adds no brief section"
}

# Each row: <label>|<expected refusal text>|<declaration line>[;<second line>]
test_unreadable_declaration_refuses() {
  local case_dir label expect lines out rc n=0
  while IFS='|' read -r label expect lines; do
    [ -n "$label" ] || continue
    n=$((n + 1))
    case_dir=$(make_case "bad-$n")
    printf '%s\n' "$lines" | tr ';' '\n' > "$case_dir/home/config/resource-locks"
    rc=0
    out=$(lock "$case_dir" 12:00 brief 2>&1) || rc=$?
    expect_code 1 "$rc" "$label: brief accepted the declaration: $out"
    assert_contains "$out" "$expect" "$label: the brief refusal did not say what is wrong"
    rc=0
    out=$(lock "$case_dir" 12:00 run ok -- sh -c ": > '$case_dir/ran'" 2>&1) || rc=$?
    expect_code 1 "$rc" "$label: run accepted the declaration: $out"
    assert_absent "$case_dir/ran" "$label: the command ran under an unreadable declaration"
  done <<'EOF'
zero slots|line 2 gives bad a slot count|ok 1 fine;bad 0 nothing may run
leading zero slots|line 2 gives bad a slot count|ok 1 fine;bad 01 heavy runs
slots not a number|line 2 gives bad a slot count|ok 1 fine;bad two heavy runs
too many digits|line 2 gives bad a slot count|ok 1 fine;bad 1000 heavy runs
no description|line 2 does not say which commands must hold bad|ok 1 fine;bad 2
window without description|line 2 does not say which commands must hold bad|ok 1 fine;bad 2 22:00-09:00=1
named twice|line 2 names ok a second time|ok 1 fine;ok 2 heavy runs
bad name|line 2: '../bad' is not a resource name|ok 1 fine;../bad 2 heavy runs
slot-shaped name|line 2: 'bad-slot-1' is not a resource name|ok 1 fine;bad-slot-1 2 heavy runs
mistyped window|line 2 gives bad a window '9:00-17:00'|ok 1 fine;bad 2 9:00-17:00=1 heavy runs
impossible hour|line 2 gives bad a window '24:00-09:00'|ok 1 fine;bad 2 24:00-09:00=1 heavy runs
empty window|line 2 gives bad a window '09:00-09:00'|ok 1 fine;bad 2 09:00-09:00=1 heavy runs
bad window count|line 2 gives bad a window count 'x'|ok 1 fine;bad 2 22:00-09:00=x heavy runs
zero window count|line 2 gives bad a window count '0'|ok 1 fine;bad 2 22:00-09:00=0 heavy runs
leading zero window count|line 2 gives bad a window count '01'|ok 1 fine;bad 2 22:00-09:00=01 heavy runs
window count too large|line 2 gives bad a window count '1000'|ok 1 fine;bad 2 22:00-09:00=1000 heavy runs
EOF
  case_dir=$(make_case bad-dir)
  mkdir "$case_dir/home/config/resource-locks"
  rc=0
  out=$(lock "$case_dir" 12:00 brief 2>&1) || rc=$?
  expect_code 1 "$rc" "a declaration that is not a file was accepted: $out"
  assert_contains "$out" "is not a readable regular file" "the refusal did not name the unusable file"
  pass "an unreadable declaration refuses brief and run rather than guessing a limit"
}

# --- brief ------------------------------------------------------------------

test_brief_gives_a_wrapper_that_runs() {
  local case_dir out wrapper rc=0
  case_dir=$(make_case brief 'suite 2 22:00-09:00=1 full test-suite runs' 'gpu 1 any GPU use')
  out=$(lock "$case_dir" 12:00 brief) || fail "brief refused a valid declaration"
  assert_contains "$out" '# Heavy commands (resource locks)' "the brief section has no heading"
  assert_contains "$out" 'take a slot yourself instead of asking firstmate' "the brief does not tell the worker to self-serve"
  assert_contains "$out" 'nest wrappers from outermost to innermost in the order the resources are listed below (declaration order)' \
    "the generated worker instructions do not specify one acquisition order"
  # shellcheck disable=SC2016 # Literal brief text.
  assert_contains "$out" '- `suite` (2 at once, 1 during 22:00-09:00) - full test-suite runs: `' \
    "the brief did not describe the resource and its hours"
  # shellcheck disable=SC2016 # Literal brief text.
  assert_contains "$out" '- `gpu` (1 at once) - any GPU use: `' "the brief did not describe the one-slot resource"
  if [ "$HAVE_FLOCK" = 0 ]; then
    echo "skip - running the brief's wrapper needs flock(1)"
  else
    # The command a worker is given, with only its placeholder filled in, must
    # work from any directory and without any firstmate environment.
    # shellcheck disable=SC2016 # Literal brief text.
    wrapper=$(printf '%s\n' "$out" | sed -n 's/^- `gpu` .*: `\(.*\) -- <command>`$/\1/p')
    [ -n "$wrapper" ] || fail "the brief line for gpu carries no wrapper command: $out"
    out=$(cd / && env -u FM_HOME -u FM_ROOT_OVERRIDE -u FM_CONFIG_OVERRIDE \
      XDG_RUNTIME_DIR="$case_dir/run" bash -c "$wrapper -- sh -c 'echo wrapped-ran; exit 7'" 2>&1) || rc=$?
    expect_code 7 "$rc" "the brief's wrapper did not return the command's status: $out"
    assert_contains "$out" 'wrapped-ran' "the brief's wrapper did not run the command"
  fi
  pass "the brief names each resource and gives a wrapper a worker can run as written"
}

# --- run --------------------------------------------------------------------

test_run_refuses_rather_than_run_unlocked() {
  local case_dir out rc=0 sans
  case_dir=$(make_case refuse 'gpu 1 any GPU use')
  out=$(lock "$case_dir" 12:00 run other -- sh -c ": > '$case_dir/ran'" 2>&1) || rc=$?
  expect_code 1 "$rc" "an undeclared resource was accepted: $out"
  assert_contains "$out" "resource 'other' is not declared" "the refusal did not name the undeclared resource"
  rc=0
  out=$(FM_HOME="$case_dir/home" FM_CONFIG_OVERRIDE='' XDG_RUNTIME_DIR="$case_dir/no-such-dir" \
    "$LOCK" run gpu -- sh -c ": > '$case_dir/ran'" 2>&1) || rc=$?
  expect_code 1 "$rc" "a missing runtime directory was accepted: $out"
  assert_contains "$out" 'XDG_RUNTIME_DIR is not a writable directory' "the refusal did not name the runtime directory"
  sans=$(fm_test_base_path_sans "$BASE_PATH" flock)
  rc=0
  out=$(PATH="$sans" lock "$case_dir" 12:00 run gpu -- sh -c ": > '$case_dir/ran'" 2>&1) || rc=$?
  expect_code 1 "$rc" "a machine without flock was accepted: $out"
  assert_contains "$out" 'flock(1) is not installed' "the refusal did not name the missing tool"
  assert_absent "$case_dir/ran" "a refused run still ran its command"
  pass "run refuses an undeclared resource, a missing runtime directory, and a missing flock without running the command"
}

test_run_passes_the_command_through() {
  local case_dir out rc=0
  case_dir=$(make_case passthrough 'gpu 1 any GPU use')
  out=$(lock "$case_dir" 12:00 run gpu -- sh -c 'printf "%s|" "$@"; exit 3' argv 'two words' '' last 2>/dev/null) || rc=$?
  expect_code 3 "$rc" "the command's exit status was not returned"
  assert_equals 'two words||last|' "$out" "the command's arguments were not passed through unchanged"
  assert_present "$case_dir/run/gpu.lock" "a one-slot resource did not use <name>.lock"
  pass "run returns the command's own status and passes its arguments unchanged"
}

test_nested_wrappers_keep_outer_slots() {
  local case_dir direction outer inner blocker nested_pid outer_pid inner_pid
  for direction in suite-gpu gpu-suite; do
    case "$direction" in
      suite-gpu)
        outer=suite inner=gpu blocker=gpu.lock
        case_dir=$(make_case "nested-$direction" 'suite 2 22:00-09:00=1 full test-suite runs' 'gpu 1 any GPU use')
        ;;
      gpu-suite)
        outer=gpu inner=suite blocker=suite-slot-2.lock
        case_dir=$(make_case "nested-$direction" 'gpu 1 any GPU use' 'suite 2 22:00-09:00=1 full test-suite runs')
        ;;
    esac
    hold_file "$case_dir/run/$blocker" "$case_dir/blocker"
    # shellcheck disable=SC2016
    lock "$case_dir" 23:00 run "$outer" -- "$LOCK" run "$inner" -- \
      sh -c '
        : > "$1.held"
        i=0
        while [ ! -e "$1.release" ] && [ "$i" -lt 300 ]; do
          i=$((i + 1))
          sleep 0.1
        done
      ' nested "$case_dir/nested" 2> "$case_dir/nested.err" &
    nested_pid=$!
    await_text "$case_dir/nested.err" "resource-lock: waiting for $inner" || fail "the nested wrapper did not wait for $inner"
    start_job "$case_dir" 23:00 "$outer" "$case_dir/outer"
    outer_pid=$!
    await_text "$case_dir/outer.err" "resource-lock: waiting for $outer" || fail "the outer slot was released while waiting for $inner"
    assert_absent "$case_dir/outer.ran" "another job ran under the nested wrapper's outer slot"
    : > "$case_dir/blocker.release"
    await_path "$case_dir/nested.held" || fail "the nested command did not run after $inner became free"
    start_job "$case_dir" 23:00 "$inner" "$case_dir/inner"
    inner_pid=$!
    await_text "$case_dir/inner.err" "resource-lock: waiting for $inner" || fail "the nested command did not keep $inner held"
    sleep 1.2
    assert_absent "$case_dir/outer.ran" "the outer slot was released while the inner command ran"
    assert_absent "$case_dir/inner.ran" "the inner slot was released while the command ran"
    : > "$case_dir/nested.release"
    wait "$nested_pid" || fail "the nested command failed"
    await_path "$case_dir/outer.ran" || fail "the outer slot was not released when the nested command finished"
    await_path "$case_dir/inner.ran" || fail "the inner slot was not released when the nested command finished"
    wait "$outer_pid" "$inner_pid" || fail "a waiting command failed after the nested command finished"
    wait
  done
  pass "nested wrappers retain both locks while waiting and running, then release both"
}

test_competing_jobs_follow_brief_order() {
  local case_dir out order outer inner first_pid second_pid
  case_dir=$(make_case competing 'suite 2 22:00-09:00=1 full test-suite runs' 'gpu 1 any GPU use')
  out=$(lock "$case_dir" 23:00 brief) || fail "brief refused the competing jobs' declaration"
  order=$(printf '%s\n' "$out" | sed -n 's/^- `\([^`]*\)`.*/\1/p')
  assert_equals $'suite\ngpu' "$order" "the brief did not preserve declaration order"
  outer=${order%%$'\n'*}
  inner=${order#*$'\n'}

  hold_file "$case_dir/run/gpu.lock" "$case_dir/blocker"
  # shellcheck disable=SC2016
  lock "$case_dir" 23:00 run "$outer" -- "$LOCK" run "$inner" -- \
    sh -c ': > "$1.ran"' job "$case_dir/first" 2> "$case_dir/first.err" &
  first_pid=$!
  await_text "$case_dir/first.err" "resource-lock: waiting for $inner" || fail "the first job did not wait for its inner resource"
  # shellcheck disable=SC2016
  lock "$case_dir" 23:00 run "$outer" -- "$LOCK" run "$inner" -- \
    sh -c ': > "$1.ran"' job "$case_dir/second" 2> "$case_dir/second.err" &
  second_pid=$!
  await_text "$case_dir/second.err" "resource-lock: waiting for $outer" || fail "the competing job did not wait for the first resource in brief order"
  assert_absent "$case_dir/first.ran" "the first job ran while its inner resource was held"
  assert_absent "$case_dir/second.ran" "the competing job ran while the first job held the outer resource"

  : > "$case_dir/blocker.release"
  await_path "$case_dir/first.ran" || fail "the first job did not finish once its inner resource became free"
  await_path "$case_dir/second.ran" || fail "the competing job deadlocked instead of finishing after the first job"
  wait "$first_pid" "$second_pid" || fail "a competing job failed"
  wait
  flock -n "$case_dir/run/gpu.lock" true || fail "the competing jobs left the GPU lock held"
  flock -n "$case_dir/run/suite-slot-1.lock" true || fail "the competing jobs left a suite slot held"
  flock -n "$case_dir/run/suite-slot-2.lock" true || fail "the competing jobs left a suite slot held"
  pass "competing jobs following brief order finish without circular waits and release both resources"
}

test_windows_select_slot_counts_for_the_hour() {
  local case_dir now limit slot tag
  while read -r now limit; do
    case_dir=$(make_case "hour-${now/:/-}" 'suite 2 22:00-09:00=1 08:00-10:00=3 full test-suite runs')
    slot=3
    while [ "$slot" -gt "$((4 - limit))" ]; do
      hold_file "$case_dir/run/suite-slot-$slot.lock" "$case_dir/h$slot"
      slot=$((slot - 1))
    done
    start_job "$case_dir" "$now" suite "$case_dir/free"
    await_path "$case_dir/free.ran" || fail "$now did not admit a job within its $limit slots"
    wait "$!" || fail "$now failed to run a job within its limit"
    tag="$case_dir/h$slot"
    hold_file "$case_dir/run/suite-slot-$slot.lock" "$tag"
    start_job "$case_dir" "$now" suite "$case_dir/full"
    await_text "$case_dir/full.err" "resource-lock: waiting for suite ($limit slot(s) at this hour" || fail "$now did not enforce its $limit slots"
    assert_absent "$case_dir/full.ran" "$now exceeded its slot limit"
    : > "$tag.release"
    await_path "$case_dir/full.ran" || fail "$now did not admit a job after a slot was released"
    for slot in 1 2 3; do
      : > "$case_dir/h$slot.release"
    done
    wait
  done <<'EOF'
21:59 2
22:00 1
23:15 1
08:59 1
09:00 3
10:00 2
EOF
  pass "run applies window boundaries, midnight crossing, first-match priority, and maximum slots"
}

# Four jobs on two slots: every job runs, and never more than two at once.
test_no_more_jobs_than_slots_run_at_once() {
  local case_dir i peak=0 now=0 event
  case_dir=$(make_case limit 'suite 2 full test-suite runs')
  for i in 1 2 3 4; do
    # shellcheck disable=SC2016 # The wrapped command expands its own argument.
    lock "$case_dir" 12:00 run suite -- sh -c 'echo start >> "$1"; sleep 0.4; echo end >> "$1"' job "$case_dir/events" \
      2>/dev/null &
  done
  wait
  while IFS= read -r event; do
    case "$event" in
      start) now=$((now + 1)) ;;
      end) now=$((now - 1)) ;;
    esac
    [ "$now" -le "$peak" ] || peak=$now
  done < "$case_dir/events"
  assert_equals 4 "$(grep -c -x start "$case_dir/events")" "not every job ran"
  [ "$peak" -le 2 ] || fail "$peak jobs held a two-slot resource at once"
  pass "a resource never runs more jobs at once than it has slots, and every job gets its turn"
}

# A job holding a slot file with plain flock is a holder like any other, so a
# lock already used by hand keeps working beside the declaration.
test_plain_flock_holders_share_the_same_slots() {
  local case_dir
  case_dir=$(make_case plain 'suite 2 full test-suite runs' 'gpu 1 any GPU use')
  hold_file "$case_dir/run/suite-slot-1.lock" "$case_dir/h1"
  start_job "$case_dir" 12:00 suite "$case_dir/free"
  await_path "$case_dir/free.ran" || fail "a job did not take the second slot while the first was held by plain flock"
  hold_file "$case_dir/run/suite-slot-2.lock" "$case_dir/h2"
  start_job "$case_dir" 12:00 suite "$case_dir/full"
  await_text "$case_dir/full.err" 'resource-lock: waiting for suite' || fail "a job did not report waiting for a full resource"
  assert_absent "$case_dir/full.ran" "a job ran while plain flock held every slot"
  : > "$case_dir/h2.release"
  await_path "$case_dir/full.ran" || fail "a waiting job did not run once a slot was released"

  hold_file "$case_dir/run/gpu.lock" "$case_dir/g1"
  start_job "$case_dir" 12:00 gpu "$case_dir/gpu"
  await_text "$case_dir/gpu.err" 'resource-lock: waiting for gpu' || fail "a job did not wait for a hand-held one-slot lock"
  assert_absent "$case_dir/gpu.ran" "a job ran while plain flock held the one-slot lock"
  : > "$case_dir/g1.release"
  await_path "$case_dir/gpu.ran" || fail "a waiting job did not run once the one-slot lock was released"
  : > "$case_dir/h1.release"
  wait
  pass "plain flock holders and wrapped jobs share the same slots, including a one-slot <name>.lock"
}

# Overnight the suite serves one job. A job still running from the day keeps
# its slot, and a new job waits for it even though another slot file is free.
test_window_lowers_the_count_for_new_jobs() {
  local case_dir
  case_dir=$(make_case window 'suite 2 22:00-09:00=1 full test-suite runs')
  hold_file "$case_dir/run/suite-slot-2.lock" "$case_dir/day"
  start_job "$case_dir" 23:00 suite "$case_dir/night"
  await_text "$case_dir/night.err" 'resource-lock: waiting for suite (1 slot(s) at this hour' ||
    fail "a night job did not wait behind a job still running from the day"
  assert_absent "$case_dir/night.ran" "two jobs held the resource during its one-slot hours"
  : > "$case_dir/day.release"
  await_path "$case_dir/night.ran" || fail "the night job did not run once the day job finished"

  wait
  pass "a window lowers the count for new jobs without evicting a running one"
}

test_declaration_renders_resources_and_windows
test_absent_declaration_declares_nothing
test_unreadable_declaration_refuses
test_brief_gives_a_wrapper_that_runs
if [ "$HAVE_FLOCK" = 0 ]; then
  echo "skip - taking resource locks needs flock(1)"
else
  test_run_refuses_rather_than_run_unlocked
  test_run_passes_the_command_through
  test_nested_wrappers_keep_outer_slots
  test_competing_jobs_follow_brief_order
  test_windows_select_slot_counts_for_the_hour
  test_no_more_jobs_than_slots_run_at_once
  test_plain_flock_holders_share_the_same_slots
  test_window_lowers_the_count_for_new_jobs
fi
