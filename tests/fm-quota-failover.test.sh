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
[ -z "${FM_TEST_QUOTA_CALLS:-}" ] || printf 'call\n' >> "$FM_TEST_QUOTA_CALLS"
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
  out=$(FM_TEST_QUOTA_CALLS="$home/calls" FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6 --effort medium)
  status=$?
  assert_equals "call" "$(cat "$home/calls")" "requested profile and alternatives must share one snapshot"
  expect_code 0 "$status" "pick past an exhausted provider"
  assert_contains "$out" "quota: codex gpt-6 is exhausted (quota-axi reports codex all_models exhausted); using pi opencode-go/kimi instead" \
    "the switch must name both profiles and the evidence"
  assert_contains "$out" "pi|opencode-go/kimi|" "the next candidate in the matching rule must be chosen"
  pass "quota-axi exhaustion moves the launch to the next configured candidate"
}

test_recorded_failure_is_honored_until_it_expires() {
  local home out status
  home=$(new_home recorded)
  failover "$home" record --harness pi --model opencode-go/kimi --why "Go usage limit exceeded" >/dev/null \
    || fail "record should succeed"
  jq -e '.scope.harness == "pi" and .scope.model == "opencode-go/kimi" and (.scope.account | length > 0)' \
    "$home/state/quota-failures" >/dev/null || fail "persisted failure must carry the exact scope"
  quota_fixture "$home/quota.json" codex exhausted_now 0
  out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6 --effort medium)
  status=$?
  expect_code 75 "$status" "recorded failure must exclude the only eligible alternative"
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness pi --model opencode-go/kimi)
  assert_contains "$out" "recorded quota failure for pi opencode-go/kimi" "the record itself must move the launch"
  assert_contains "$out" "codex|gpt-6|medium" "the first other rule candidate must be chosen"
  failover "$home" record --harness claude --model claude-opus-5-5 --until 1 >/dev/null
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness claude --model claude-opus-5-5 --effort high)
  assert_equals "claude|claude-opus-5-5|high" "$out" "an expired record must not move the launch"
  pass "a recorded quota failure moves launches until it expires"
}

test_every_candidate_exhausted_defers() {
  local home out status
  home=$(new_home defer)
  failover "$home" record --harness pi --model opencode-go/kimi >/dev/null
  quota_fixture "$home/quota.json" codex exhausted_now 0
  out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6 --effort medium)
  status=$?
  expect_code 75 "$status" "pick with nothing left"
  assert_contains "$out" "deferred: codex gpt-6 is exhausted" "the deferral must say why"
  pass "with every configured candidate exhausted the launch defers with exit 75"
}

test_only_unambiguous_matching_arrays_supply_alternatives() {
  local home out status config
  home=$(new_home matching)
  failover "$home" record --harness codex --model gpt-6 >/dev/null
  for config in \
    '{"rules":[],"default":[{"harness":"claude"}]}' \
    '{"rules":[{"use":{"harness":"codex","model":"gpt-6"}}],"default":[{"harness":"claude"}]}' \
    '{"rules":[{"use":[{"harness":"codex"},{"harness":"claude"}]}]}' \
    '{"rules":[{"use":[{"harness":"codex","model":"gpt-6"},{"harness":"claude"}]},{"use":[{"harness":"codex","model":"gpt-6"},{"harness":"grok"}]}]}' \
    '{"rules":[{"use":[{"harness":"codex","model":"gpt-6"},{"harness":"claude"}]}],"default":[{"harness":"codex","model":"gpt-6"},{"harness":"grok"}]}' \
    '{"default":[{"harness":"codex","model":"gpt-6","effort":"high"},{"harness":"codex","model":"gpt-6","effort":"low"}]}'; do
    printf '%s\n' "$config" > "$home/config/crew-dispatch.json"
    out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness codex --model gpt-6)
    status=$?
    expect_code 75 "$status" "no unique eligible alternative: $config"
    assert_contains "$out" "no configured alternative exists" "deferral must explain the missing alternative"
  done
  printf '%s\n' '{"default":[{"harness":"codex","model":"gpt-6"},{"harness":"claude"}]}' > "$home/config/crew-dispatch.json"
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness codex --model gpt-6)
  expect_code 0 "$?" "a uniquely matching default array"
  assert_contains "$out" "claude||" "the matching default must provide its own alternative"
  failover "$home" record --harness codex >/dev/null
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness codex)
  expect_code 75 "$?" "an omitted requested model must not match a named model"
  pass "only an exact, unique matching entry supplies alternatives"
}

test_failure_scope_is_exact() {
  local home out model harness account
  home=$(new_home scopes)
  printf '%s\n' '{"default":[{"harness":"pi","model":"openai-codex-work/gpt-6","provider":"codex"},{"harness":"codex","model":"gpt-6"}]}' > "$home/config/crew-dispatch.json"
  failover "$home" record --harness pi --model openai-codex-work/gpt-6 >/dev/null
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness pi --model openai-codex-work/gpt-6)
  expect_code 0 "$?" "Pi exhaustion must leave native Codex eligible"
  assert_contains "$out" "codex|gpt-6|" "a recorded Pi failure must not block native Codex"
  for model in openai-codex-personal/gpt-6 openai-codex-work/gpt-7 ''; do
    out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness pi --model "$model")
    assert_equals "pi|$model|" "$out" "a narrower record must not block another lane/model or an omitted model"
  done
  for harness in pi pi-signed claude codex; do
    for account in a b; do mkdir -p "$home/$account"; done
    out=$(PI_CODING_AGENT_DIR="$home/a" CLAUDE_CONFIG_DIR="$home/a" CODEX_HOME="$home/a" \
      failover "$home" record --harness "$harness" --model scoped)
    expect_code 0 "$?" "record with ambient credential source"
    out=$(PI_CODING_AGENT_DIR="$home/b" CLAUDE_CONFIG_DIR="$home/b" CODEX_HOME="$home/b" FM_TEST_QUOTA_JSON='' \
      failover "$home" pick --harness "$harness" --model scoped)
    assert_equals "$harness|scoped|" "$out" "ambient credential roots must not share failures"
  done
  for harness in claude pi pi-signed; do
    case "$harness" in claude) account=claude-account ;; *) account=pi-account ;; esac
    printf '%s\n' "$home/a" > "$home/config/$account"
    [ "$harness" = claude ] || printf 'openai-codex-work\n' >> "$home/config/$account"
    failover "$home" record --harness "$harness" --model openai-codex-work/gpt-6 >/dev/null
    printf '%s\n' "$home/b" > "$home/config/$account"
    [ "$harness" = claude ] || printf 'openai-codex-work\n' >> "$home/config/$account"
    out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness "$harness" --model openai-codex-work/gpt-6)
    assert_equals "$harness|openai-codex-work/gpt-6|" "$out" "different account pins must not share failures"
  done
  printf 'codex\t9999999999\tlegacy\n' >> "$home/state/quota-failures"
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness codex --model gpt-6)
  assert_equals "codex|gpt-6|" "$out" "provider-only legacy records must not block a launch"
  pass "failure records isolate runtimes, account sources, and exact models"
}

test_unknown_providers_ignore_live_quota() {
  local home out harness
  home=$(new_home unknown-provider)
  quota_fixture "$home/quota.json" codex exhausted_now 0
  for harness in opencode pi pi-signed omp; do
    printf '{"default":[{"harness":"%s","model":"custom"},{"harness":"claude"}]}\n' "$harness" > "$home/config/crew-dispatch.json"
    out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model custom)
    assert_equals "$harness|custom|" "$out" "undeclared multi-provider identity must stay unknown"
    failover "$home" record --harness "$harness" --model custom >/dev/null
    out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model custom)
    assert_contains "$out" "claude||" "an exact recorded failure still applies without a provider declaration"
    printf '{"default":[{"harness":"codex","model":"gpt-6"},{"harness":"%s","model":"other"}]}\n' "$harness" > "$home/config/crew-dispatch.json"
    out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6)
    assert_contains "$out" "$harness|other|" "an undeclared alternative must not inherit another provider's exhaustion"
  done
  for harness in opencode pi pi-signed omp; do
    printf '{"default":[{"harness":"%s","model":"specific","provider":"codex"},{"harness":"claude"}]}\n' "$harness" > "$home/config/crew-dispatch.json"
    out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness")
    assert_equals "$harness||" "$out" "missing models must not inherit a named profile's provider"
    out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model specific)
    assert_contains "$out" "claude||" "exact declared providers must still use live evidence"
    printf '{"default":[{"harness":"%s","provider":"codex"},{"harness":"claude"}]}\n' "$harness" > "$home/config/crew-dispatch.json"
    out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model specific)
    assert_equals "$harness|specific|" "$out" "named models must not inherit an unqualified profile's provider"
  done
  pass "multi-provider profiles require exact provider declarations for live evidence"
}

test_account_scoped_live_evidence_survives_unrelated_records() {
  local home out
  home=$(new_home lanes)
  printf '%s\n' '{"default":[{"harness":"codex","model":"gpt-6"},{"harness":"pi","model":"openai-codex-work/gpt-6","provider":"codex"}]}' > "$home/config/crew-dispatch.json"
  quota_fixture "$home/base.json" codex exhausted_now 0
  jq '.schemaVersion=6 | .providers[0].accountKey="openai-codex-work" |
    .providers += [(.providers[0] | .accountKey="codex-home" |
      .quotaSemantics.effectiveAvailability[0].effectivePercentRemaining=50 |
      .quotaSemantics.effectiveAvailability[0].runway.status="through_reset")]' "$home/base.json" > "$home/quota.json"
  failover "$home" record --harness pi --model openai-codex-work/other >/dev/null
  out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6)
  assert_equals "codex|gpt-6|" "$out" "a healthy native Codex account must stay available"
  out=$(FM_TEST_QUOTA_CALLS="$home/calls" FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness pi --model openai-codex-work/gpt-6)
  expect_code 0 "$?" "account-scoped exhaustion must switch to the healthy account"
  assert_contains "$out" "quota-axi reports codex all_models exhausted" "unmatched records must not hide live account evidence"
  assert_contains "$out" "codex|gpt-6|" "the healthy account must remain eligible"
  assert_equals "call" "$(cat "$home/calls")" "account checks must share one snapshot"
  pass "live evidence binds to the account and remains consulted with unrelated records"
}

test_pinned_profiles_ignore_ambient_quota() {
  local home out harness model pin_file schema
  for harness in claude pi pi-signed; do
    case "$harness" in
      claude) pin_file=claude-account; model=claude-opus-5-5 ;;
      *) pin_file=pi-account; model=anthropic/claude-opus-5-5 ;;
    esac
    for schema in 5 6; do
      home=$(new_home "pinned-$harness-$schema")
      mkdir -p "$home/account-b" "$home/account-c"
      printf '{"default":[{"harness":"codex","model":"gpt-6"},{"harness":"%s","model":"%s","provider":"claude"}]}\n' \
        "$harness" "$model" > "$home/config/crew-dispatch.json"
      quota_fixture "$home/base.json" claude exhausted_now 0
      jq --argjson schema "$schema" '.schemaVersion=$schema |
        if $schema == 6 then .providers[0].accountKey="default" else . end' \
        "$home/base.json" > "$home/quota.json"
      out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model "$model")
      expect_code 0 "$?" "unpinned $harness with schema $schema"
      assert_contains "$out" "quota-axi reports claude all_models exhausted" "unpinned live evidence must still apply"
      assert_contains "$out" "codex|gpt-6|" "an exhausted unpinned profile must switch"

      printf '%s\n' "$home/account-b" > "$home/config/$pin_file"
      [ "$harness" = claude ] || printf 'anthropic\n' >> "$home/config/$pin_file"
      out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model "$model")
      expect_code 0 "$?" "pinned $harness with schema $schema"
      assert_equals "$harness|$model|" "$out" "ambient exhaustion must not move a pinned profile"

      failover "$home" record --harness codex --model gpt-6 >/dev/null || fail "record requested failure"
      out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6)
      expect_code 0 "$?" "pinned $harness alternative with schema $schema"
      assert_contains "$out" "$harness|$model|" "ambient exhaustion must not exclude a pinned alternative"

      failover "$home" record --harness "$harness" --model "$model" >/dev/null || fail "record pinned failure"
      out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model "$model")
      expect_code 75 "$?" "exact pinned failure with no available alternative"
      assert_contains "$out" "recorded quota failure for $harness $model" "pinned failures must still apply at their exact scope"
      out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness codex --model gpt-6)
      expect_code 75 "$?" "recorded pinned failures must also exclude alternatives"

      printf '%s\n' "$home/account-c" > "$home/config/$pin_file"
      [ "$harness" = claude ] || printf 'anthropic\n' >> "$home/config/$pin_file"
      out=$(FM_TEST_QUOTA_JSON="$home/quota.json" failover "$home" pick --harness "$harness" --model "$model")
      expect_code 0 "$?" "different pinned account with schema $schema"
      assert_equals "$harness|$model|" "$out" "neither ambient nor differently scoped exhaustion may block another pin"
    done
  done
  pass "pinned profiles ignore ambient quota while exact recorded failures remain effective"
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

test_relaunch_uses_recorded_account_and_default_model() {
  local home out
  home=$(new_home relaunch-account)
  mkdir -p "$home/old" "$home/new"
  printf '%s\n' "$home/new" > "$home/config/claude-account"
  printf '%s\n' '{"default":[{"harness":"claude"},{"harness":"codex"}]}' > "$home/config/crew-dispatch.json"
  write_task "$home" task-pin claude default default
  printf 'account=%s\n' "$home/old" >> "$home/state/task-pin.meta"
  printf '%s\n' "You've hit your usage limit." > "$home/pane.txt"
  out=$(FM_TEST_PANE="$home/pane.txt" FM_TEST_QUOTA_JSON='' relaunch "$home" task-pin)
  expect_code 0 "$?" "relaunch must match the default model and stopped worker's scope: $out"
  jq -e --arg account "$home/old" '.scope.account == $account and .scope.model == ""' \
    "$home/state/quota-failures" >/dev/null || fail "failure must retain the stopped worker's account and normalized model"
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness claude --model default)
  assert_equals "claude||" "$out" "the old worker's failure must not block the new account pin"
  printf '%s\n' "$home/old" > "$home/config/claude-account"
  out=$(FM_TEST_QUOTA_JSON='' failover "$home" pick --harness claude)
  assert_contains "$out" "codex||" "the same old account must still match its recorded failure"
  pass "relaunch records the stopped account and normalizes default metadata"
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
test_only_unambiguous_matching_arrays_supply_alternatives
test_failure_scope_is_exact
test_unknown_providers_ignore_live_quota
test_account_scoped_live_evidence_survives_unrelated_records
test_pinned_profiles_ignore_ambient_quota
test_relaunch_switches_once_on_a_genuine_quota_failure
test_relaunch_uses_recorded_account_and_default_model
test_relaunch_ignores_transient_and_old_messages
test_relaunch_without_quota_left_changes_nothing
test_home_is_required
echo "# all fm-quota-failover tests passed"
