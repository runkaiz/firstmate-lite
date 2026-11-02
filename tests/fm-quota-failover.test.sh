#!/usr/bin/env bash
# Behavior tests for bin/fm-quota-failover.sh.
#
# Drives the public pick/record/relaunch interface. quota-axi is a PATH stub
# serving a fixture snapshot, and relaunch runs from a copy of bin/ whose
# fm-peek.sh serves a fixture terminal and whose fm-control.sh records the
# lifecycle call it would have made, so no real worker or terminal is touched.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

TMP_ROOT=$(fm_test_tmproot fm-quota-failover)
FAKEBIN="$TMP_ROOT/fakebin"
COPY="$TMP_ROOT/root"
mkdir -p "$FAKEBIN" "$COPY"
cp -R "$ROOT/bin" "$COPY/bin"

cat > "$FAKEBIN/quota-axi" <<'SH'
#!/usr/bin/env bash
[ -n "${FM_TEST_QUOTA_JSON:-}" ] || exit 1
cat "$FM_TEST_QUOTA_JSON"
SH
cat > "$COPY/bin/fm-peek.sh" <<'SH'
#!/usr/bin/env bash
cat "$FM_TEST_PANE"
SH
cat > "$COPY/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$@" >> "$FM_TEST_CONTROL_LOG"
printf -- '--\n' >> "$FM_TEST_CONTROL_LOG"
exit "${FM_TEST_CONTROL_STATUS:-0}"
SH
chmod +x "$FAKEBIN/quota-axi" "$COPY/bin/fm-peek.sh" "$COPY/bin/fm-control.sh"

DISPATCH='{"rules":[{"when":"systems","use":[{"harness":"codex","model":"gpt-6","effort":"medium"},{"harness":"pi","model":"opencode-go/kimi","provider":"opencode-go"}]}],"default":{"harness":"claude","model":"claude-opus-5-5","effort":"high"}}'

new_home() {  # <name>
  local home="$TMP_ROOT/$1"
  mkdir -p "$home/state" "$home/config"
  printf '%s\n' "$DISPATCH" > "$home/config/crew-dispatch.json"
  printf '%s\n' "$home"
}

quota_fixture() {  # <file> <provider> <runway> <percent>
  printf '{"schemaVersion":5,"providers":[{"provider":"%s","quotaSemantics":{"status":"known","effectiveAvailability":[{"scope":"all_models","status":"known","effectivePercentRemaining":%s,"runway":{"status":"%s"}}]}}]}\n' \
    "$2" "$4" "$3" > "$1"
}

failover() {  # <home> <args...>
  local home=$1
  shift
  FM_HOME="$home" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' PATH="$FAKEBIN:$PATH" \
    "$ROOT/bin/fm-quota-failover.sh" "$@" 2>&1
}

relaunch() {  # <home> <id>
  FM_HOME="$1" FM_STATE_OVERRIDE='' FM_CONFIG_OVERRIDE='' PATH="$FAKEBIN:$PATH" \
    FM_TEST_CONTROL_LOG="$1/control.log" \
    "$COPY/bin/fm-quota-failover.sh" relaunch "$2" 2>&1
}

write_task() {  # <home> <id> <harness> <model> <effort>
  printf 'kind=ship\nharness=%s\nmodel=%s\neffort=%s\n' "$3" "$4" "$5" > "$1/state/$2.meta"
}

test_available_profile_is_kept() {
  local home out status
  home=$(new_home keep)
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness codex --model gpt-6 --effort medium)
  status=$?
  expect_code 0 "$status" "pick with no quota evidence"
  assert_equals "codex|gpt-6|medium" "$out" "an unmeasured profile must launch unchanged"
  quota_fixture "$home/quota.json" codex through_reset 40
  out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6 --effort medium)
  assert_equals "codex|gpt-6|medium" "$out" "a profile with headroom must launch unchanged"
  pass "a profile not known to be exhausted launches unchanged"
}

test_quota_axi_exhaustion_moves_to_next_candidate() {
  local home out status
  home=$(new_home axi)
  quota_fixture "$home/quota.json" codex exhausted_now 0
  out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6 --effort medium)
  status=$?
  expect_code 0 "$status" "pick past an exhausted provider"
  assert_contains "$out" "quota: codex gpt-6 is exhausted (quota-axi reports codex all_models exhausted); using pi opencode-go/kimi instead" \
    "the switch must name both profiles and the evidence"
  assert_contains "$out" "pi|opencode-go/kimi|" "the next candidate in the matching rule must be chosen"
  pass "quota-axi exhaustion moves the launch to the next configured candidate"
}

test_recorded_failure_is_honored_until_it_expires() {
  local home out
  home=$(new_home recorded)
  failover "$home" record --harness pi --model opencode-go/kimi --why "Go usage limit exceeded" >/dev/null \
    || fail "record should succeed"
  assert_grep "opencode-go" "$home/state/quota-failures" "the declared provider must key the record"
  quota_fixture "$home/quota.json" codex exhausted_now 0
  out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6 --effort medium)
  assert_contains "$out" "claude|claude-opus-5-5|high" "a recorded failure must skip that candidate"
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness pi --model opencode-go/kimi)
  assert_contains "$out" "recorded quota failure for opencode-go" "the record itself must move the launch"
  assert_contains "$out" "codex|gpt-6|medium" "the first other rule candidate must be chosen"
  printf 'claude\t1\told\n' >> "$home/state/quota-failures"
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness claude --model claude-opus-5-5 --effort high)
  assert_equals "claude|claude-opus-5-5|high" "$out" "an expired record must not move the launch"
  pass "a recorded quota failure moves launches until it expires"
}

test_every_candidate_exhausted_defers() {
  local home out status
  home=$(new_home defer)
  failover "$home" record --harness claude >/dev/null
  failover "$home" record --harness pi --model opencode-go/kimi >/dev/null
  quota_fixture "$home/quota.json" codex exhausted_now 0
  out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6 --effort medium)
  status=$?
  expect_code 75 "$status" "pick with nothing left"
  assert_contains "$out" "deferred: codex gpt-6 is exhausted" "the deferral must say why"
  pass "with every configured candidate exhausted the launch defers with exit 75"
}

test_unlisted_profile_falls_back_to_default() {
  local home out
  home=$(new_home unlisted)
  failover "$home" record --harness grok >/dev/null
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness grok --model grok-4)
  assert_contains "$out" "claude|claude-opus-5-5|high" "a profile in no rule must fall back to the default set"
  pass "a profile named by no rule falls back to the default profiles"
}

test_relaunch_switches_once_on_a_genuine_quota_failure() {
  local home out status
  home=$(new_home relaunch)
  write_task "$home" task-a pi opencode-go/kimi ''
  printf '%s\n' 'working on the brief' 'Error: 429: {"type":"GoUsageLimitError","message":"Go usage limit exceeded"}' '' '> ' \
    > "$home/pane.txt"
  out=$(FM_TEST_PANE="$home/pane.txt" FM_TEST_QUOTA_JSON='' relaunch "$home" task-a)
  status=$?
  expect_code 0 "$status" "relaunch after a quota failure: $out"
  assert_contains "$out" "quota-failover: task 'task-a' moved from pi opencode-go/kimi to codex gpt-6" \
    "the outcome must name both runtimes"
  assert_grep "task-a" "$home/control.log" "fm-control must receive the exact task id"
  assert_grep "relaunch" "$home/control.log" "fm-control must be asked to relaunch"
  assert_grep "codex" "$home/control.log" "the replacement harness must be passed"
  assert_grep "gpt-6" "$home/control.log" "the replacement model must be passed"
  assert_grep "same local copy" "$home/control.log" "a progress note must be passed"
  assert_grep "opencode-go" "$home/state/quota-failures" "the failure must be recorded for later spawns"
  assert_present "$home/state/task-a.quota-failover" "the once-only guard must be written"
  out=$(FM_TEST_PANE="$home/pane.txt" relaunch "$home" task-a)
  status=$?
  expect_code 1 "$status" "a second switch"
  assert_contains "$out" "already switched runtime once" "the second switch must be refused"
  [ "$(grep -c '^relaunch$' "$home/control.log")" = 1 ] || fail "fm-control must be called exactly once"
  pass "a genuine quota failure switches the worker once and never loops"
}

test_relaunch_ignores_transient_and_old_messages() {
  local home out status i
  home=$(new_home transient)
  write_task "$home" task-b codex gpt-6 medium
  printf '%s\n' 'stream error: 429 Too Many Requests (rate limit), retrying' 'Overloaded' '> ' > "$home/pane.txt"
  out=$(FM_TEST_PANE="$home/pane.txt" FM_TEST_QUOTA_JSON='' relaunch "$home" task-b)
  status=$?
  expect_code 3 "$status" "a transient rate limit"
  assert_contains "$out" "no quota failure is visible" "a transient limit must change nothing"
  printf '%s\n' "You've hit your usage limit." > "$home/pane.txt"
  for i in $(seq 1 13); do printf 'later line %s\n' "$i" >> "$home/pane.txt"; done
  out=$(FM_TEST_PANE="$home/pane.txt" FM_TEST_QUOTA_JSON='' relaunch "$home" task-b)
  status=$?
  expect_code 3 "$status" "a quota message scrolled above the recent lines"
  assert_absent "$home/control.log" "fm-control must never be called without a current quota failure"
  assert_absent "$home/state/quota-failures" "nothing must be recorded without a current quota failure"
  pass "transient rate limits and scrolled-away messages never trigger a switch"
}

test_relaunch_without_quota_left_changes_nothing() {
  local home out status
  home=$(new_home relaunch-defer)
  write_task "$home" task-c claude claude-opus-5-5 high
  failover "$home" record --harness codex >/dev/null
  failover "$home" record --harness pi --model opencode-go/kimi >/dev/null
  printf '%s\n' "You've hit your limit · resets 3pm" > "$home/pane.txt"
  out=$(FM_TEST_PANE="$home/pane.txt" FM_TEST_QUOTA_JSON='' relaunch "$home" task-c)
  status=$?
  expect_code 75 "$status" "relaunch with nothing left"
  assert_absent "$home/control.log" "no relaunch may happen without a candidate"
  assert_absent "$home/state/task-c.quota-failover" "the guard is written only for a real switch"
  pass "with no candidate left a quota-stopped worker is reported, not relaunched"
}

test_home_is_required() {
  local out status
  out=$(env -u FM_HOME "$ROOT/bin/fm-quota-failover.sh" pick --harness codex 2>&1)
  status=$?
  expect_code 2 "$status" "pick without FM_HOME"
  assert_contains "$out" "FM_HOME is not set" "the refusal must name the missing home"
  pass "an unnamed home is refused"
}

test_available_profile_is_kept
test_quota_axi_exhaustion_moves_to_next_candidate
test_recorded_failure_is_honored_until_it_expires
test_every_candidate_exhausted_defers
test_unlisted_profile_falls_back_to_default
test_relaunch_switches_once_on_a_genuine_quota_failure
test_relaunch_ignores_transient_and_old_messages
test_relaunch_without_quota_left_changes_nothing
test_home_is_required
echo "# all fm-quota-failover tests passed"
