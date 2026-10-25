#!/usr/bin/env bash
# Behavior tests for the bearings projection wrapper over fm-fleet-snapshot.sh.
# Covers the output/token bound, TOON/JSON parity, the local-only default (zero
# GitHub/network calls), the --include-prs opt-in path, graceful degradation on a
# partial PR-fetch failure, end-to-end unresolved-decision durability, and current
# report pointers.
set -u

# shellcheck source=tests/lib.sh
# shellcheck disable=SC1091
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
# shellcheck disable=SC1091
# shellcheck source=bin/fm-tasks-axi-lib.sh
# shellcheck disable=SC1091
. "$ROOT/bin/fm-tasks-axi-lib.sh"

BEARINGS="$ROOT/bin/fm-bearings-snapshot.sh"
TASKS_AXI_BIN=$(command -v tasks-axi || true)
TMP_ROOT=$(fm_test_tmproot fm-bearings)
# Keep disposable homes outside the snapshot's fixture repo boundary even when
# TMPDIR is inside an isolated source worktree.
FM_ROOT_OVERRIDE="$TMP_ROOT/fixture-root"
mkdir -p "$FM_ROOT_OVERRIDE"
export FM_ROOT_OVERRIDE

command -v jq >/dev/null 2>&1 || { echo "skip: jq not found"; exit 0; }

# A fakebin that stubs the local tools the canonical snapshot may reach for, plus a
# gh/gh-axi that RECORDS every call to $NET_LOG so a test can prove the default path
# makes no network call. gh returns one fixture open PR keyed to the ship task.
make_fakebin() {  # <dir>
  local fb
  fb=$(fm_fakebin "$1")
  cat > "$fb/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "${FAKE_NM_SLEEP:-0}" = 1 ] && sleep 30
exit 0
SH
  cat > "$fb/tmux" <<'SH'
#!/usr/bin/env bash
case "${1:-}" in
  display-message) case "$*" in *dead-*) exit 1 ;; *) printf '%%1\n' ;; esac ;;
  capture-pane)
    case "$*" in
      *fm-domain-alpha*) printf 'stale terminal summary: Phase 7 started\n> \n' ;;
      *) printf 'all quiet\n> \n' ;;
    esac
    ;;
esac
exit 0
SH
  cat > "$fb/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then exit 1; fi
if [ "${FAKE_GH_SLEEP:-0}" = 1 ]; then sleep 30; fi
if [ "${FAKE_GH_MANY:-0}" = 1 ]; then
  cat <<'JSON'
[{"number":1,"title":"One","url":"https://github.com/acme/repo/pull/1","headRefName":"fm/one","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":2,"title":"Two","url":"https://github.com/acme/repo/pull/2","headRefName":"fm/two","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]},{"number":3,"title":"Three","url":"https://github.com/acme/repo/pull/3","headRefName":"fm/three","reviewDecision":"","mergeable":"MERGEABLE","statusCheckRollup":[]}]
JSON
  exit 0
fi
cat <<'JSON'
[{"number":9,"title":"Ship the thing","url":"https://github.com/kunchenguid/firstmate/pull/9","headRefName":"fm/ship-task","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]
JSON
SH
  cat > "$fb/gh-axi" <<'SH'
#!/usr/bin/env bash
echo "gh-axi $*" >> "$NET_LOG"
[ "${FAKE_GH_FAIL:-0}" = 1 ] && exit 1
exit 0
SH
  cat > "$fb/curl" <<'SH'
#!/usr/bin/env bash
echo "curl $*" >> "$NET_LOG"
exit 1
SH
  chmod +x "$fb/no-mistakes" "$fb/tmux" "$fb/gh" "$fb/gh-axi" "$fb/curl"
  printf '%s\n' "$fb"
}

make_home() {  # <name>
  local home=$TMP_ROOT/$1
  mkdir -p "$home/state" "$home/data" "$home/projects" "$home/config"
  printf '%s\n' "$home"
}

record_claude_state() {  # <state-dir> <id> <busy|idle>
  local state=$1 id=$2 semantic_state=$3 gen event
  case "$semantic_state" in
    busy) event=user-prompt-submit ;;
    idle) event=stop ;;
    *) fail "unsupported semantic fixture state: $semantic_state" ;;
  esac
  gen=$("$ROOT/bin/fm-busy-event.sh" arm "$state" "$id")
  "$ROOT/bin/fm-busy-event.sh" apply "$state" "$id" "$semantic_state" --gen "$gen" \
    --source claude-hook --event "$event"
}

fixture_mate_home() {  # <parent-home>
  printf '%s/%s-secondmate-home\n' "$TMP_ROOT" "$(basename "$1")"
}

# Standard fixture: a ship task with a recorded PR, a scout task with a report, a
# secondmate with a MASKED open decision (needs-decision then a later unrelated
# done), and a backlog with a superseded queued item.
write_fixture() {  # <home>
  local home=$1 mate
  mate=$(fixture_mate_home "$home")
  mkdir -p "$home/projects/ship-wt" "$home/data/scout-x" "$mate/data" "$mate/state" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'mate\n' > "$mate/.fm-secondmate-home"
  printf -- '- mate - fixture domain (home: %s; scope: fixture work; projects: firstmate; added 2026-07-11)\n' \
    "$mate" > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<EOF
## In flight
- [ ] ship-task - Ship the thing (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] scout-x - Investigate the thing data/scout-x/report.md (repo: firstmate) (kind: scout) (since 2026-07-11)

## Queued
- [ ] live-gate - Real queued work blocked-by: ship-task (repo: firstmate) (kind: ship)
- [ ] dead-gate - Old conditional work (repo: firstmate) (kind: scout)
  NOT REQUIRED - superseded 2026-07-11; kept as reference only.

## Done
- [x] done-a - Landed thing https://github.com/kunchenguid/firstmate/pull/7 (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF
  printf '# Scout X\n' > "$home/data/scout-x/report.md"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  record_claude_state "$home/state" ship-task busy
  printf 'working: building the thing\n' > "$home/state/ship-task.status"
  fm_write_meta "$home/state/scout-x.meta" \
    "window=firstmate:fm-scout-x" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=scout" \
    "mode=scout"
  record_claude_state "$home/state" scout-x idle
  printf 'done: report ready\n' > "$home/state/scout-x.status"
  fm_write_meta "$home/state/mate.meta" \
    "window=firstmate:fm-mate" \
    "worktree=$mate" \
    "project=$mate" \
    "harness=codex" \
    "kind=secondmate" \
    "mode=secondmate" \
    "home=$mate" \
    "projects=firstmate"
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$home/state/mate.status"
  printf 'done: an unrelated subtask finished\n' >> "$home/state/mate.status"
  fm_write_meta "$home/state/external-wait.meta" \
    "window=firstmate:fm-external-wait" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes"
  record_claude_state "$home/state" external-wait idle
  printf 'paused: declared external-wait for upstream release\n' > "$home/state/external-wait.status"
  # The secondmate's OWN home backlog records a merge it managed. This lands in the
  # secondmate home, never the main backlog, so landed-work views only see it via the
  # bounded cross-home Done roll-up.
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight
- [ ] mate - Decide subscription order (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] mate-decision-race - Choose subscription order (repo: firstmate) (kind: captain) (hold: captain choice pending) (hold-kind: captain)

## Done
- [x] mate-landed - Secondmate-managed fix https://github.com/kunchenguid/firstmate/pull/50 (repo: firstmate) (kind: ship) (merged 2026-07-11)
EOF
  mkdir -p "$mate/projects/mate"
  fm_write_meta "$mate/state/mate.meta" \
    "window=firstmate:fm-mate" "worktree=$mate/projects/mate" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" mate idle
  printf 'needs-decision [key=race]: pick subscribe order\n' > "$mate/state/mate.status"
}



run() {  # <home> <fakebin> <args...>
  local home=$1 fakebin=$2; shift 2
  PATH="$fakebin:$PATH" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" "$BEARINGS" "$@"
}

run_captain() {  # <home> <fakebin> <command args...>
  local home=$1 fakebin=$2
  shift 2
  PATH="$fakebin:$PATH" REAL_TASKS_AXI="$TASKS_AXI_BIN" FM_ROOT_OVERRIDE="$ROOT" \
    FM_HOME="$home" FM_STATE_OVERRIDE="$home/state" FM_DATA_OVERRIDE="$home/data" \
    FM_CONFIG_OVERRIDE="$home/config" "$ROOT/bin/fm-captain-hold.sh" "$@"
}

write_remote_home_summary() {  # <remote-home> <generated-epoch>
  local home=$1 epoch=$2
  mkdir -p "$home/state"
  jq -n --arg home "$home" --argjson epoch "$epoch" '{
    schema:"fm-secondmate-home-summary.v1",
    hold_classifier_schema:"fm-captain-hold-buckets.v1",
    generated:"2026-09-01T22:00:00Z",generated_epoch:$epoch,home:$home,
    valid:true,reason:null,invalidity:{kind:null,ids:[]},state:"captain_decision",
    active_children:[],
    decisions_open:[
      {id:"remote-parked",key:"remote-parked",verb:"captain-hold",summary:"Remote parked hold",reason:"parked",hold_until:null,hold_bucket:"live",hold_age_days:null,source:"backlog"},
      {id:"remote-aged",key:"remote-aged",verb:"captain-hold",summary:"Remote aged hold",reason:"choose a route",hold_until:null,hold_bucket:"aged",hold_age_days:40,source:"backlog"}
    ],holds:[],
    queued:[
      {id:"remote-parked",title:"Remote parked hold",blocked_by:null,blocked_by_ids:[],unresolved_blocker_ids:[],blocked_reason:null,hold_reason:"parked",hold_kind:"captain",hold_until:null,hold_bucket:"live",hold_age_days:null,captain_actionable:true,repo:"firstmate",kind:"captain"},
      {id:"remote-aged",title:"Remote aged hold",blocked_by:null,blocked_by_ids:[],unresolved_blocker_ids:[],blocked_reason:null,hold_reason:"choose a route",hold_kind:"captain",hold_until:null,hold_bucket:"aged",hold_age_days:40,captain_actionable:false,repo:"firstmate",kind:"captain"}
    ],landed:[],endpoints:[],
    counts:{active_children:0,decisions_open:2,holds:0,queued:2,landed:0,endpoints:0},omitted:[]
  }' > "$home/state/home-summary.json"
}

make_remote_ledger_fleet() {  # <parent-home> <count>
  local parent=$1 count=$2 i id remote_home
  mkdir -p "$parent/data" "$parent/state" "$parent/config" "$parent/projects"
  : > "$parent/data/backlog.md"
  : > "$parent/data/secondmates.md"
  i=1
  while [ "$i" -le "$count" ]; do
    id="ledger-$i"
    remote_home="$TMP_ROOT/remote-ledger-home-$i"
    mkdir -p "$remote_home/state"
    remote_home=$(cd "$remote_home" && pwd -P)
    printf -- '- %s - ledger fixture (host: host-%s; root: /remote/root; home: %s; scope: fixture; projects: sample; added 2026-09-01)\n' \
      "$id" "$i" "$remote_home" >> "$parent/data/secondmates.md"
    fm_write_meta "$parent/state/$id.meta" \
      "kind=secondmate" "mode=secondmate" "harness=pi" \
      "remote_host=host-$i" "remote_root=/remote/root" "home=$remote_home"
    write_remote_home_summary "$remote_home" 1000
    i=$((i + 1))
  done
}

make_remote_ledger_ssh() {  # <dir>
  local dir=$1 fb="$1/fakebin"
  mkdir -p "$fb"
  cat > "$fb/fake-ssh" <<'SH'
#!/usr/bin/env bash
set -u
while [ "$#" -gt 0 ]; do
  case "$1" in -o) shift 2 ;; --) shift; break ;; *) exit 90 ;; esac
done
shift 2
remote_home=$(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$3")
args=()
while IFS= read -r -d '' arg; do args+=("$arg"); done \
  < <(perl -MMIME::Base64=decode_base64 -e 'print decode_base64($ARGV[0])' "$4")
printf '%s\t%s\n' "$remote_home" "${args[0]:-}" >> "$FM_TEST_LEDGER_CALL_LOG"
if [ -f "$remote_home/state/slow-ledger-read" ]; then
  active_marker="$FM_TEST_LEDGER_ACTIVE_DIR/collector-$$"
  : > "$active_marker"
  trap 'rm -f "$active_marker"' EXIT
  while [ ! -f "$FM_TEST_LEDGER_ACTIVE_DIR/overlap-proved" ]; do
    set -- "$FM_TEST_LEDGER_ACTIVE_DIR"/collector-*
    if [ "$#" -ge 5 ] && [ -e "$1" ]; then
      : > "$FM_TEST_LEDGER_ACTIVE_DIR/overlap-proved"
      break
    fi
    sleep 0.05
  done
  sleep 30 &
  sleeper=$!
  printf '%s %s\n' "$$" "$sleeper" >> "$FM_TEST_LEDGER_PID_LOG"
  wait "$sleeper"
fi
case "${args[0]:-}" in
  fm-remote-file.sh)
    [ -f "$remote_home/state/home-summary.json" ] || exit 1
    if [ -f "$remote_home/state/unbounded-ledger-read" ]; then
      yes x
    else
      cat "$remote_home/state/home-summary.json"
    fi
    ;;
  *) exit 91 ;;
esac
SH
  chmod +x "$fb/fake-ssh"
  printf '%s\n' "$fb"
}

run_remote_ledger_bearings() {  # <parent-home> <fakebin> <epoch>
  local parent=$1 fakebin=$2 epoch=$3
  # Allow process startup on loaded hosts; the 30-second fake reads still
  # exceed this shared deadline and must be cancelled.
  FM_HOME="$parent" FM_ROOT_OVERRIDE="$ROOT" FM_SSH_BIN="$fakebin/fake-ssh" \
    FM_TEST_LEDGER_CALL_LOG="$parent/ledger-calls.log" \
    FM_TEST_LEDGER_PID_LOG="$parent/ledger-pids.log" \
    FM_TEST_LEDGER_ACTIVE_DIR="$parent/ledger-active" \
    FM_SNAPSHOT_CACHE_DIR="$parent/state/summary-cache" \
    FM_SNAPSHOT_BUDGET=15 FM_SNAPSHOT_NOW_EPOCH="$epoch" \
    FM_BEARINGS_NOW=2026-09-01T22:00:00Z "$BEARINGS" --json
}

# End-to-end Domain Alpha regression fixture.
# The parent event claims Phase 7 started, while the registered home has no child
# metadata, every sample-rollout item is Done, and only an external legal hold remains.
write_domain_alpha_fixture() {  # <parent-home> <secondmate-home>
  local home=$1 mate=$2 i
  mkdir -p "$mate/state" "$mate/data" "$mate/config" "$mate/projects" "$mate/bin"
  printf '# Firstmate fixture\n' > "$mate/AGENTS.md"
  printf 'domain-alpha\n' > "$mate/.fm-secondmate-home"
  printf -- '- domain-alpha - sample rollout (home: %s; scope: sample rollout and legal release; projects: sample; added 2026-07-13)\n' \
    "$mate" > "$home/data/secondmates.md"
  fm_write_secondmate_meta "$home/state/domain-alpha.meta" "$mate" "firstmate:fm-domain-alpha" sample
  printf 'working [key=phase7]: Phase 7 started\n' > "$home/state/domain-alpha.status"
  cat > "$mate/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] legal-release - Release approval blocked-by: external-legal - external legal dependency (repo: sample) (kind: ship)

## Done
EOF
  i=1
  while [ "$i" -le 7 ]; do
    printf -- '- [x] phase%s - Sample rollout Phase %s (repo: sample) (kind: ship) (done 2026-07-%02d)\n' \
      "$i" "$i" "$i" >> "$mate/data/backlog.md"
    i=$((i + 1))
  done
  refresh_local_secondmate_ledgers "$home"
}

# This is the Domain Alpha failure shape exactly: the structured home says Phase 7 is Done
# and no child is active, so the stale parent event must never become Underway.










make_valid_secondmate_home() {  # <id> <home>
  local id=$1 home=$2
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects" "$home/bin"
  printf '# Firstmate fixture\n' > "$home/AGENTS.md"
  printf '%s\n' "$id" > "$home/.fm-secondmate-home"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued

## Done
EOF
}

append_secondmate_registry() {  # <parent> <id> <home>
  printf -- '- %s - fixture domain (home: %s; scope: fixture; projects: sample; added 2026-07-13)\n' \
    "$2" "$3" >> "$1/data/secondmates.md"
}

append_landed_row() {  # <secondmate-home> <id> <title> <date>
  printf -- '- [x] %s - %s (repo: firstmate) (kind: ship) (merged %s)\n' \
    "$2" "$3" "$4" >> "$1/data/backlog.md"
}

make_landed_secondmate() {  # <parent> <id>
  local parent=$1 id=$2 mate
  mate="$TMP_ROOT/$(basename "$parent")-$id-home"
  make_valid_secondmate_home "$id" "$mate"
  append_secondmate_registry "$parent" "$id" "$mate"
  printf '%s\n' "$mate"
}

write_parent_secondmate_event() {  # <parent> <id> <home> <note>
  fm_write_secondmate_meta "$1/state/$2.meta" "$3" "firstmate:fm-$2" sample
  printf 'working [key=%s]: %s\n' "$2" "$4" > "$1/state/$2.status"
}















test_current_landed_baseline_is_repeatable_and_prior_report_independent() {
  local home fakebin one two
  home=$(make_home standalone-baseline); write_fixture "$home"
  cat > "$home/data/status-report-2026-07-10.md" <<'EOF'
# Misleading old report

## Recently Landed
- fake-old-item

## Underway
- Phase 7 started
EOF
  fakebin=$(make_fakebin "$home")
  one=$(run "$home" "$fakebin" --json)
  two=$(run "$home" "$fakebin" --json)
  [ "$(printf '%s' "$one" | jq -c '.landed')" = "$(printf '%s' "$two" | jq -c '.landed')" ] \
    || fail "the same structured state produced different recent-completion baselines"
  printf '%s' "$two" | jq -e '
    (.landed | any(.id == "done-a"))
      and (.landed | any(.id == "fake-old-item") | not)
      and (.in_flight | any(.doing == "Phase 7 started") | not)
  ' >/dev/null || fail "prior status report influenced the standalone snapshot: $two"
  pass "repeated snapshots keep the same current landed baseline and ignore prior reports"
}

test_default_is_bounded_and_local_only() {
  local home fakebin toon json backlog
  home=$(make_home bounded); write_fixture "$home"
  backlog="$home/data/backlog.md"
  awk '{if ($0 ~ /^- \[ \] ship-task /) sub(/ \(repo: firstmate\)/, ""); print}' \
    "$backlog" > "$backlog.tmp" && mv "$backlog.tmp" "$backlog"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Bound: well under the ~50 KB tool-display limit.
  [ "${#toon}" -lt 50000 ] || fail "default TOON must stay under the display bound, got ${#toon}"
  # TOON is materially smaller than the canonical snapshot it projects.
  local canon; canon=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  [ "${#toon}" -lt "${#canon}" ] || fail "projection must be smaller than the canonical snapshot"
  # Local-only: no GitHub/network call on the default path.
  [ ! -s "$home/net.log" ] || fail "default run must make no gh/gh-axi call, got: $(cat "$home/net.log")"
  # Definitive not-requested PR state, never a silent omission.
  assert_contains "$toon" 'prs: "not_requested' "default must state PR checks were not requested"
  assert_contains "$toon" "live PR discovery + checks,\"--include-prs\"" "omitted must mark the dropped live-PR surface"
  # Valid JSON, correct schema.
  printf '%s' "$json" | jq -e '
    .schema == "fm-bearings.v1"
      and (.in_flight | any(.id == "ship-task" and .repo == "firstmate"))
  ' >/dev/null || fail "json schema or main Underway repository wrong: $json"
  pass "default output is bounded, local-only, and marks omitted surfaces"
}

test_toon_json_parity() {
  local home fakebin toon json keys k
  home=$(make_home parity); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toon=$(run "$home" "$fakebin")
  json=$(run "$home" "$fakebin" --json)
  # Same top-level keys in both representations.
  keys=$(printf '%s' "$json" | jq -r 'keys_unsorted[]')
  for k in $keys; do
    if printf '%s' "$json" | jq -e --arg k "$k" '.[$k] | type == "array"' >/dev/null; then
      local n hdr
      n=$(printf '%s' "$json" | jq --arg k "$k" '.[$k] | length')
      if [ "$n" = 0 ]; then
        assert_contains "$toon" "$k: []" "empty array $k must render as 'key: []'"
      else
        # Header must declare the same count and the same field set.
        hdr=$(printf '%s' "$toon" | grep -E "^$k\[[0-9]+\]\{" || true)
        [ -n "$hdr" ] || fail "TOON missing tabular header for $k"
        assert_contains "$hdr" "[$n]" "TOON $k row count must equal JSON length $n"
        local jfields tfields
        jfields=$(printf '%s' "$json" | jq -r --arg k "$k" '.[$k][0] | keys_unsorted | join(",")')
        tfields=$(printf '%s' "$hdr" | sed -E 's/^[^{]*\{//; s/\}:.*$//; s/"//g')
        [ "$jfields" = "$tfields" ] || fail "TOON $k fields ($tfields) must equal JSON fields ($jfields)"
      fi
    else
      # Scalar: the key must appear as a "key: value" line.
      assert_contains "$toon" "$k: " "TOON must carry scalar field $k"
    fi
  done
  pass "TOON and JSON are parity representations of the same model"
}



test_report_pointers_surface() {
  local home fakebin json
  home=$(make_home reports); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e --arg p "$home/data/scout-x/report.md" '
    .reports | any(.[]; .id == "scout-x" and .path == $p)
  ' >/dev/null || fail "current scout report pointer must surface: $json"
  pass "current report pointers surface"
}

test_queued_item_prose_never_hides_it() {
  local home fakebin json
  home=$(make_home superseded); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.gates | any(.[]; .id == "live-gate")) and (.gates | any(.[]; .id == "dead-gate"))
  ' >/dev/null || fail "queued body prose must not hide a gate from the default board: $json"
  json=$(run "$home" "$fakebin" --json --all-queued)
  printf '%s' "$json" | jq -e '
    (.gates | any(.[]; .id == "dead-gate"))
      and (.omitted | any(.reveal == "--all-queued") | not)
  ' >/dev/null || fail "--all-queued must not advertise a suppression that no longer exists: $json"
  pass "queued body prose never hides an item from the board"
}

# The collapsed captain-call contract: any due, unblocked captain-held task is
# Captain's Call whatever its kind; a date-deferred hold is a dated gate until
# due; deferral wording in the reason changes nothing, because only structured
# fields classify; and Recently Landed applies the shared delivery selector to
# Done rows.
test_collapsed_captain_call_deferral_and_landed() {
  local home fakebin json
  home=$(make_home collapsed-call)
  mkdir -p "$home/data"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] work-gate - Captain-gated ship work (repo: firstmate) (kind: ship) (hold: captain go needed) (hold-kind: captain)
- [ ] later-call - Deferred captain call (repo: firstmate) (kind: captain) (hold: revisit with the captain) (hold-kind: captain) (hold-until: 2026-08-01)
- [ ] due-call - Due captain call (repo: firstmate) (kind: captain) (hold: overdue captain choice) (hold-kind: captain) (hold-until: 2026-07-11)
- [ ] parked-call - Prose-parked captain call (repo: firstmate) (kind: ship) (hold: DEFERRED by captain revisit later) (hold-kind: captain)
- [ ] external-gate - Externally held work (repo: firstmate) (kind: ship) (hold: upstream release pending) (hold-kind: external)

## Done
- [x] answered-call - Answered captain question (repo: firstmate) (kind: captain) (done 2026-07-10) (hold: captain choice pending) (hold-kind: captain)
- [x] shipped-work - Ordinary landed work (repo: firstmate) (kind: ship) (merged 2026-07-10)
EOF
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "work-gate"))
      and (.decisions_open | any(.[]; .id == "due-call"))
      and (.decisions_open | any(.[]; .id == "later-call") | not)
      and (.decisions_open | any(.[]; .id == "parked-call"))
      and (.decisions_open | any(.[]; .id == "external-gate") | not)
      and (.gates | any(.[]; .id == "later-call" and (.reason | startswith("until 2026-08-01"))))
      and (.gates | any(.[]; .id == "work-gate") | not)
      and (.gates | any(.[]; .id == "parked-call") | not)
      and (.gates | any(.[]; .id == "external-gate"))
      and (.landed | any(.[]; .id == "shipped-work"))
      and (.landed | any(.[]; .id == "answered-call") | not)
      and (.omitted | any(.[]; .surface | startswith("captain holds bucketed blocked, dated, or aged")))
  ' >/dev/null || fail "the collapsed captain-call projection is wrong: $json"
  json=$(run "$home" "$fakebin" --json --all-decisions --all-queued)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "parked-call"))
      and (.gates | any(.[]; .id == "parked-call") | not)
  ' >/dev/null || fail "--all-decisions must reveal the prose-deferred call: $json"
  pass "captain-held tasks of any kind reach Captain's Call, deferral is honored, and landed excludes answered calls"
}

test_undated_hold_phrasing_and_aging_projection() {
  local home fakebin json
  home=$(make_home undated-aging-proj)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] parked-hold - Parked style call (repo: firstmate) (kind: ship) (since 2026-07-10) (hold: not urgent) (hold-kind: captain)
- [ ] blocked-parked - Blocked parked call blocked-by: missing-blocker (repo: firstmate) (kind: captain) (hold: parked) (hold-kind: captain)
- [ ] future-parked - Parked style call for later (repo: firstmate) (kind: captain) (hold: parked) (hold-kind: captain) (hold-until: 2026-08-01)
- [ ] due-parked - Parked style call now due (repo: firstmate) (kind: captain) (hold: parked) (hold-kind: captain) (hold-until: 2026-07-11)
- [ ] due-superseded - Superseded call now due (repo: firstmate) (kind: captain) (hold: SUPERSEDED) (hold-kind: captain) (hold-until: 2026-07-11)
- [ ] aged-call - Aged genuine call (repo: firstmate) (kind: captain) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z
- [ ] recent-call - Recent genuine call (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: choose a sample route) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] contextual-call - Context is not a deferral (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: choose whether to pursue this queued opportunity) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
  This is not urgent context, but the captain decision is current.
- [ ] contextual-not-urgent - Leading context is not a deferral (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: not urgent but choose the route now) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] contextual-comma - Comma context is not a deferral (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: not urgent, choose the launch route now) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] metadata-context - Metadata-like context is not a deferral (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: not urgent, priority: decide P1 or P2) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] contextual-opportunity - Leading opportunity is not a deferral (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: queued opportunity: choose whether to proceed) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] contextual-gated - Leading gate is not a deferral (repo: firstmate) (kind: captain) (since 2026-07-10) (hold: captain-gated decision needs current approval) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] reheld-current-call - Re-held genuine call (repo: firstmate) (kind: captain) (since 2026-06-01) (hold: choose a current sample route) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
  Current decision prose lists route north or route south.
  Resolution recorded by fm-captain-hold.
  Decision digest: historical-sample
  Resolution mode: released
  Captain decision:
  Not urgent at the time of the previous call.
- [ ] legacy-old-hold - Legacy unstamped hold (repo: firstmate) (kind: ship) (since 2026-06-01) (hold: choose a sample route) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.decisions_open[].id] | contains(["recent-call", "due-parked", "parked-hold", "due-superseded",
      "contextual-call", "contextual-not-urgent", "contextual-comma", "metadata-context",
      "contextual-opportunity", "contextual-gated", "reheld-current-call"]))
      and ([.decisions_open[].id] | any(. == "future-parked" or . == "blocked-parked" or . == "aged-call" or . == "legacy-old-hold") | not)
      and (.decisions_open | any(.id == "contextual-comma" and .summary == "Comma context is not a deferral: not urgent, choose the launch route now"))
      and (.decisions_open | any(.id == "metadata-context" and .summary == "Metadata-like context is not a deferral: not urgent, priority: decide P1 or P2"))
      and (.gates | any(.id == "future-parked" and .reason == "until 2026-08-01: parked"))
      and (.gates | any(.id == "blocked-parked" and .blocked_by == "missing-blocker"))
      and (.gates | any(.id == "aged-call" and (.reason | startswith("held 40d"))))
      and (.gates | any(.id == "legacy-old-hold" and (.reason | startswith("held 40d"))))
      and (.omitted | any(.surface == "captain holds bucketed blocked, dated, or aged: 4"))
  ' >/dev/null || fail "structured buckets must decide decision placement: $json"
  json=$(run "$home" "$fakebin" --json --all-decisions)
  printf '%s' "$json" | jq -e '
    (.decisions_open | length) == 15
      and ([.gates[].id] | any(. == "parked-hold" or . == "aged-call" or . == "legacy-old-hold" or . == "future-parked" or . == "blocked-parked") | not)
  ' >/dev/null || fail "all-decisions must reveal every hold without duplicate gates: $json"
  json=$(FM_SNAPSHOT_UNDATED_HOLD_AGE_DAYS=50 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "aged-call")) and (.gates | any(.id == "aged-call") | not)
  ' >/dev/null || fail "raising the age threshold must restore the hold: $json"
  pass "structured hold buckets decide decisions, gates, and the reveal"
}

test_blocked_deferred_hold_has_concrete_disclosure() {
  local home fakebin json
  home=$(make_home blocked-deferred-disclosure)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] only-blocked-parked - Blocked parked call blocked-by: missing-blocker (repo: firstmate) (kind: captain) (hold: parked) (hold-kind: captain) (hold-until: 2026-07-11)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.gates | any(.id == "only-blocked-parked" and .blocked_by == "missing-blocker"
                  and (.reason | startswith("blocked-by missing-blocker"))))
      and (.omitted | any(.surface == "captain holds bucketed blocked, dated, or aged: 1"))
  ' >/dev/null || fail "a lone blocked deferred hold lacked its concrete disclosure: $json"
  json=$(run "$home" "$fakebin" --json --all-decisions)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "only-blocked-parked" and .verb == "captain-hold"))
      and (.gates | any(.id == "only-blocked-parked") | not)
  ' >/dev/null || fail "--all-decisions did not reveal a blocked deferred hold whose date had arrived: $json"
  pass "a blocked deferred hold stays gated when its date arrives and is revealed by --all-decisions"
}

test_revealed_deferred_holds_show_their_deferral_reason() {
  local home fakebin json
  home=$(make_home revealed-deferral-reason)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] reveal-blocked - Blocked parked call blocked-by: missing-blocker-1234567890123456789012345678901234567890 (repo: firstmate) (kind: captain) (hold: parked) (hold-kind: captain)
- [ ] reveal-future - 1234567890123456789012345678901234567890123456789012345678901234567890123456789012345678901234567890 (repo: firstmate) (kind: captain) (hold: parked) (hold-kind: captain) (hold-until: 2026-12-01)
- [ ] reveal-aged - Aged undated call (repo: firstmate) (kind: captain) (since 2026-06-01) (hold: choose a route) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z
- [ ] reveal-live - 123456789012345678901234567890123456789012345678901234567890 (repo: firstmate) (kind: captain) (hold: choose A) (hold-kind: captain)

## Done
EOF
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json --all-decisions)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "reveal-blocked"
      and (.summary | contains("blocked-by missing-blocker-1234567890123456789012345678901234567890"))))
  ' >/dev/null || fail "a revealed blocked hold must show its complete blocked-by identity: $json"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "reveal-future" and (.summary | contains("until 2026-12-01"))))
  ' >/dev/null || fail "a revealed date-deferred hold must show its until date: $json"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "reveal-aged" and (.summary | contains("held ") and contains("d: "))))
  ' >/dev/null || fail "a revealed aged hold must show its age: $json"
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "reveal-live"
       and .summary == "123456789012345678901234567890123456789012345678901234567890: choose A"
       and (.summary | contains("blocked-by") or contains("until ") or contains("held ") | not)))
  ' >/dev/null || fail "a long-titled live call must remain complete and unannotated: $json"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.decisions_open[].id] == ["reveal-live"])
      and (.decisions_open[0].summary == "123456789012345678901234567890123456789012345678901234567890: choose A")
      and (.gates | any(.id == "reveal-blocked"))
      and (.gates | any(.id == "reveal-future"))
      and (.gates | any(.id == "reveal-aged"))
  ' >/dev/null || fail "the default board must keep deferred holds gated and show only the live call: $json"
  pass "revealed deferred holds display their deferral reason while live calls stay unannotated"
}

test_include_prs_is_the_only_fetch_path() {
  local home fakebin json
  home=$(make_home prs); write_fixture "$home"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(run "$home" "$fakebin" --include-prs --json)
  # Now gh WAS called, exactly for pr list.
  grep -q '^gh pr list ' "$home/net.log" || fail "--include-prs must call gh pr list"
  printf '%s' "$json" | jq -e '
    .prs | startswith("checked")
  ' >/dev/null || fail "--include-prs must report checked PR state"
  printf '%s' "$json" | jq -e '
    .candidate_prs | any(.[]; .num == "9" and .task == "ship-task" and .checks == "passing" and .review == "APPROVED")
  ' >/dev/null || fail "candidate_prs must carry the fetched PR cross-referenced to its task: $json"
  pass "--include-prs is the only path that fetches, and it enriches correctly"
}

test_include_prs_maps_custom_branch_prefix_to_task() {
  local home fakebin json
  home=$(make_home custom-prefix); write_fixture "$home"
  fm_write_meta "$home/state/ship-task.meta" \
    "window=firstmate:fm-ship-task" \
    "worktree=$home/projects/ship-wt" \
    "project=firstmate" \
    "harness=claude" \
    "kind=ship" \
    "mode=no-mistakes" \
    "branch=fix/ship-task" \
    "pr=https://github.com/kunchenguid/firstmate/pull/9"
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
echo "gh $*" >> "$NET_LOG"
if [ "${FAKE_GH_FAIL:-0}" = 1 ]; then exit 1; fi
cat <<'JSON'
[{"number":9,"title":"Ship the thing","url":"https://github.com/kunchenguid/firstmate/pull/9","headRefName":"fix/ship-task","reviewDecision":"APPROVED","mergeable":"MERGEABLE","statusCheckRollup":[{"conclusion":"SUCCESS","status":"COMPLETED"}]}]
JSON
SH
  chmod +x "$fakebin/gh"
  json=$(run "$home" "$fakebin" --include-prs --json)
  printf '%s' "$json" | jq -e '
    .candidate_prs | any(.[]; .num == "9" and .task == "ship-task")
  ' >/dev/null || fail "a PR on a custom (non-fm/) branch prefix must still map to its recorded task, not fall to '-': $json"
  pass "--include-prs maps a custom branch-prefix PR back to its recorded task"
}

test_partial_github_failure_degrades() {
  local home fakebin json rc
  home=$(make_home partial); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FAKE_GH_FAIL=1 run "$home" "$fakebin" --include-prs --json); rc=$?
  expect_code 0 "$rc" "a PR-fetch failure must not crash the view"
  printf '%s' "$json" | jq -e '
    .schema == "fm-bearings.v1"
      and (.candidate_prs | length) == 0
      and (.prs | test("unavailable"))
      and (.in_flight | length) > 0
  ' >/dev/null || fail "on gh failure the view must still emit, with an unavailable note: $json"
  pass "a partial GitHub failure degrades gracefully"
}

test_perl_fallback_bounds_github_call() {
  local home fakebin toolbin cmd json started elapsed
  home=$(make_home perl-timeout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  toolbin="$home/toolbin"
  mkdir -p "$toolbin"
  for cmd in bash dirname basename jq date sed git grep tail cut tr head sort wc perl sleep cat find mktemp rm mkdir chmod mv cp awk; do
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  for cmd in shasum sha256sum; do
    command -v "$cmd" >/dev/null 2>&1 || continue
    ln -s "$(command -v "$cmd")" "$toolbin/$cmd"
  done
  started=$(date +%s)
  json=$(PATH="$fakebin:$toolbin" FM_HOME="$home" FM_BEARINGS_NOW=2026-07-11T18:00:00Z \
    FM_BEARINGS_PR_TIMEOUT=1 NET_LOG="$home/net.log" FAKE_GH_SLEEP=1 "$BEARINGS" --include-prs --json)
  elapsed=$(( $(date +%s) - started ))
  [ "$elapsed" -lt 10 ] || fail "Perl fallback did not bound a stalled gh call (${elapsed}s)"
  printf '%s' "$json" | jq -e '.prs | test("unavailable")' >/dev/null \
    || fail "timed-out gh call did not fail soft: $json"
  pass "Perl fallback bounds stalled GitHub calls without coreutils timeout"
}

write_large_fixture() {  # <home> <count>
  local home=$1 count=$2 i id
  : > "$home/data/backlog.md"
  printf '## Queued\n' >> "$home/data/backlog.md"
  i=1
  while [ "$i" -le "$count" ]; do
    id="dead-$i"
    mkdir -p "$home/projects/$id" "$home/data/$id"
    printf '# Report\n' > "$home/data/$id/report.md"
    printf -- '- [ ] gate-%s - Gate %s blocked-by: task-%s (repo: repo-%s) (kind: ship)\n' "$i" "$i" "$i" "$i" >> "$home/data/backlog.md"
    printf -- '- [ ] decision-%s - Decision %s (repo: repo-%s) (kind: captain) (hold: captain choice pending) (hold-kind: captain)\n' "$i" "$i" "$i" >> "$home/data/backlog.md"
    fm_write_meta "$home/state/$id.meta" \
      "window=firstmate:fm-$id" \
      "worktree=$home/projects/$id" \
      "project=repo-$i" \
      "harness=codex" \
      "kind=scout" \
      "mode=scout" \
      "pr=https://github.com/acme/repo-$i/pull/$i"
    printf 'needs-decision [key=q%s]: choose %s\n' "$i" "$i" > "$home/state/$id.status"
    i=$((i + 1))
  done
}

test_section_caps_and_expansion_flags() {
  local home fakebin json expanded
  home=$(make_home caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight|length) == 2 and (.decisions_open|length) == 2 and (.gates|length) == 2
    and (.reports|length) == 2 and (.recorded_prs|length) == 2 and (.unhealthy_endpoints|length) == 2
    and ([.omitted[].surface] | index("in_flight showing 2 of 5") != null)
    and ([.omitted[].surface] | index("decisions_open showing 2 of 5") != null)
    and ([.omitted[].surface] | index("gates showing 2 of 5") != null)
    and ([.omitted[].surface] | index("reports showing 2 of 5") != null)
    and ([.omitted[].surface] | index("recorded_prs showing 2 of 5") != null)
    and ([.omitted[].surface] | index("unhealthy_endpoints showing 2 of 5") != null)
  ' >/dev/null || fail "section caps or counted omissions are wrong: $json"
  expanded=$(FM_BEARINGS_IN_FLIGHT=2 FM_BEARINGS_DECISIONS=2 FM_BEARINGS_GATES=2 \
    FM_BEARINGS_REPORTS=2 FM_BEARINGS_RECORDED_PRS=2 FM_BEARINGS_UNHEALTHY=2 \
    run "$home" "$fakebin" --json --all-in-flight --all-decisions --all-queued \
      --all-reports --all-recorded-prs --all-unhealthy)
  printf '%s' "$expanded" | jq -e '
    (.in_flight|length) == 5 and (.decisions_open|length) == 5 and (.gates|length) == 5
    and (.reports|length) == 5 and (.recorded_prs|length) == 5 and (.unhealthy_endpoints|length) == 5
  ' >/dev/null || fail "section expansion flags did not reveal full sets: $expanded"
  pass "all fleet-sized sections are capped with counted opt-in expansion"
}

test_pr_repository_cap_and_expansion() {
  local home fakebin json expanded
  home=$(make_home repo-caps); write_large_fixture "$home" 5
  fakebin=$(make_fakebin "$home"); : > "$home/net.log"
  json=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 2 ] || fail "default PR repository cap was not enforced"
  printf '%s' "$json" | jq -e '
    [.omitted[] | select(.surface == "PR repositories showing 2 of 5" and .reveal == "--all-pr-repos")] | length == 1
  ' >/dev/null || fail "PR repository truncation was not recorded: $json"
  : > "$home/net.log"
  expanded=$(FM_BEARINGS_PR_REPOS=2 run "$home" "$fakebin" --include-prs --all-pr-repos --json)
  [ "$(grep -c '^gh pr list ' "$home/net.log")" = 5 ] || fail "--all-pr-repos did not reveal every repository"
  printf '%s' "$expanded" | jq -e '.candidate_prs | length == 5' >/dev/null \
    || fail "expanded PR repository set did not enrich every repository: $expanded"
  pass "live PR enrichment caps repositories with counted expansion"
}

test_per_repository_pr_cap_is_disclosed() {
  local home fakebin json toon
  home=$(make_home pr-row-cap); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs --json)
  toon=$(FM_BEARINGS_PR_LIMIT=2 FAKE_GH_MANY=1 run "$home" "$fakebin" --include-prs)
  printf '%s' "$json" | jq -e '
    (.candidate_prs | length) == 2
    and (.prs | test("2 shown, at least 3 open; capped in 1 repo"))
    and ([.omitted[] | select(.surface == "candidate_prs showing 2 of at least 3; capped in 1 repo(s)" and .reveal == "raise FM_BEARINGS_PR_LIMIT")] | length) == 1
  ' >/dev/null || fail "per-repository PR truncation was not disclosed: $json"
  assert_contains "$toon" 'candidate_prs showing 2 of at least 3' "TOON did not preserve PR truncation disclosure"
  pass "per-repository open-PR caps are disclosed with an expansion knob"
}

install_failing_jq() {  # <fakebin> <model|toon>
  local fakebin=$1 phase=$2 real
  real=$(command -v jq)
  cat > "$fakebin/jq" <<SH
#!/usr/bin/env bash
case "\$*" in
  *'def trunc'*) [ "$phase" = model ] && exit 9 ;;
  *'def q:'*) [ "$phase" = toon ] && exit 9 ;;
esac
exec "$real" "\$@"
SH
  chmod +x "$fakebin/jq"
}

test_projection_and_toon_fail_closed() {
  local home fakebin out err rc
  home=$(make_home fail-closed); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  install_failing_jq "$fakebin" model
  err="$home/model.err"
  out=$(run "$home" "$fakebin" --json 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "projection failure exited successfully"
  [ -z "$out" ] || fail "projection failure emitted output"
  grep -F 'projection failed' "$err" >/dev/null || fail "projection failure lacked a diagnostic"
  install_failing_jq "$fakebin" toon
  err="$home/toon.err"
  out=$(run "$home" "$fakebin" 2> "$err"); rc=$?
  [ "$rc" -ne 0 ] || fail "TOON rendering failure exited successfully"
  [ -z "$out" ] || fail "TOON rendering failure emitted output"
  grep -F 'TOON rendering failed' "$err" >/dev/null || fail "TOON failure lacked a diagnostic"
  pass "projection and TOON rendering failures exit nonzero with diagnostics"
}

# The Lavish-103 defect, end to end: a COMPLETED scout that raised a decision and
# then finished (done), whose report body reads like that decision, must surface as
# a report POINTER only - never in decisions_open. Report prose must never open or
# reopen a pending decision; only the keyed durable state does.
test_completed_scout_report_not_pending() {
  local home fakebin json
  home=$(make_home completed-scout); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  mkdir -p "$home/projects/lav-wt" "$home/data/lavish-103"
  fm_write_meta "$home/state/lavish-103.meta" \
    "window=firstmate:fm-lavish-103" \
    "worktree=$home/projects/lav-wt" \
    "project=firstmate" \
    "harness=codex" \
    "kind=scout" \
    "mode=scout"
  printf 'needs-decision: adopt approach A or B for Lavish issue 103\n' > "$home/state/lavish-103.status"
  printf 'done: report ready at data/lavish-103/report.md\n' >> "$home/state/lavish-103.status"
  printf '# Lavish 103\nThe open question is whether to adopt approach A or B; this needs a captain decision.\n' > "$home/data/lavish-103/report.md"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.[]; .id == "lavish-103") | not)
      and (.reports | any(.[]; .id == "lavish-103"))
  ' >/dev/null || fail "completed scout must be a report pointer, never a pending decision: $json"
  pass "a completed scout with decision-like report prose is a pointer, not pending"
}

# Recently Landed must include merges a secondmate managed. Those completion records
# live in the secondmate home's OWN backlog, not the main one, so the projection must
# roll them up. Local, deterministic, no GitHub call.


# Recently Landed accepts only the artifact owned by a row's task kind and
# completion path. Answered captain questions are the negative boundary.
test_landed_accepts_only_kind_owned_delivery_artifacts() {
  local home fakebin json main_backlog report_path report_pr
  local keyword_report shipping_report fleet_json created_kind failures=''
  [ -n "$TASKS_AXI_BIN" ] || fail "tasks-axi is required for the landed-selector regression"
  fm_tasks_axi_compatible || {
    echo "skip: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so the real backlog mutations this regression needs are refused"
    return 0
  }
  home=$(make_home kind-owned-landed)
  write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  main_backlog="$home/data/backlog.md"

  "$TASKS_AXI_BIN" add answered-question \
    "Decide whether https://github.com/o/r/pull/7 may merge" --kind ship \
    --repo firstmate --file "$main_backlog" >/dev/null \
    || fail "could not create the answered captain question"
  run_captain "$home" "$fakebin" hold answered-question \
    --reason "captain route choice pending" >/dev/null \
    || fail "could not hold the answered captain question"
  printf 'Choose route north.\n' > "$home/question-answer.txt"
  run_captain "$home" "$fakebin" answer answered-question \
    --decision-file "$home/question-answer.txt" >/dev/null \
    || fail "could not close the answered captain question"

  run_captain "$home" "$fakebin" hold created-local-question \
    --title "Choose local main" --reason "captain local route pending" >/dev/null \
    || fail "could not create the local-only captain question"
  created_kind=$("$TASKS_AXI_BIN" show created-local-question --full --file "$main_backlog" \
    | sed -n 's/^  kind: *//p' | head -1)
  run_captain "$home" "$fakebin" answer created-local-question \
    --decision-file "$home/question-answer.txt" >/dev/null \
    || fail "could not close the local-only captain question"

  "$TASKS_AXI_BIN" add legacy-local-question "Choose local main" \
    --repo firstmate --file "$main_backlog" >/dev/null \
    || fail "could not create the legacy kindless captain question"
  run_captain "$home" "$fakebin" hold legacy-local-question \
    --reason "captain legacy local route pending" >/dev/null \
    || fail "could not hold the legacy kindless captain question"
  run_captain "$home" "$fakebin" answer legacy-local-question \
    --decision-file "$home/question-answer.txt" >/dev/null \
    || fail "could not close the legacy kindless captain question"

  keyword_report="data/keyword-scout/report.md"
  shipping_report="data/shipping-scout/report.md"
  mkdir -p "$home/data/keyword-scout" "$home/data/shipping-scout"
  printf '# Keyword scout\n' > "$home/$keyword_report"
  printf '# Shipping scout\n' > "$home/$shipping_report"
  "$TASKS_AXI_BIN" add keyword-scout "SCOUT parser keywords" --kind scout \
    --repo firstmate --start --file "$main_backlog" >/dev/null \
    || fail "could not create the canonical keyword scout"
  "$TASKS_AXI_BIN" 'done' keyword-scout --report "$keyword_report" \
    --file "$main_backlog" >/dev/null \
    || fail "could not complete the canonical keyword scout"
  "$TASKS_AXI_BIN" add keyword-local "SHIP keyword local main" --kind ship \
    --repo firstmate --start --file "$main_backlog" >/dev/null \
    || fail "could not create the canonical keyword local delivery"
  "$TASKS_AXI_BIN" 'done' keyword-local --note "local main" \
    --file "$main_backlog" >/dev/null \
    || fail "could not complete the canonical keyword local delivery"
  "$TASKS_AXI_BIN" add noted-local "Land the local-only change" --kind ship \
    --repo firstmate --start --file "$main_backlog" >/dev/null \
    || fail "could not create the recorded-note local delivery"
  "$TASKS_AXI_BIN" 'done' noted-local --note "local main" \
    --file "$main_backlog" >/dev/null \
    || fail "could not complete the recorded-note local delivery"
  "$TASKS_AXI_BIN" add legacy-noted-local "Complete the legacy work" \
    --repo firstmate --start --file "$main_backlog" >/dev/null \
    || fail "could not create the kindless local delivery"
  "$TASKS_AXI_BIN" 'done' legacy-noted-local --note "local main" \
    --file "$main_backlog" >/dev/null \
    || fail "could not complete the kindless local delivery"
  "$TASKS_AXI_BIN" add shipping-scout "SHIPPING parser boundary" --kind scout \
    --repo firstmate --start --file "$main_backlog" >/dev/null \
    || fail "could not create the longer-word scout"
  "$TASKS_AXI_BIN" 'done' shipping-scout --report "$shipping_report" \
    --file "$main_backlog" >/dev/null \
    || fail "could not complete the longer-word scout"

  report_path="data/reported-scout/report.md"
  report_pr="https://github.com/o/r/pull/8"
  mkdir -p "$home/data/reported-scout"
  printf '# Reported scout\n' > "$home/$report_path"
  cat >> "$main_backlog" <<EOF
- [x] done-pr-nondelivery - Closed without merge https://github.com/o/r/pull/5 (repo: firstmate) (kind: ship) (done 2026-07-12)
- [x] scout-pr-no-report - Scout without report https://github.com/o/r/pull/6 (repo: firstmate) (kind: scout) (merged 2026-07-12)
- [x] ship-reported-path - Ship naming data/ship-reported-path/report.md (repo: firstmate) (kind: ship) (reported 2026-07-12)
- [x] reported-scout - Report with $report_pr context $report_path (repo: firstmate) (kind: scout) (reported 2026-07-12)
- [x] local-delivery - Local with https://github.com/o/r/pull/9 context local main (repo: firstmate) (kind: ship) (done 2026-07-12)
EOF

  : > "$home/net.log"
  fleet_json=$(PATH="$fakebin:$PATH" FM_HOME="$home" \
    FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z NET_LOG="$home/net.log" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "Fleet snapshot failed for canonical kind keywords"
  printf '%s' "$fleet_json" | jq -e '
    (.backlog.records | any(.id == "keyword-scout" and .kind == "scout"))
      and (.backlog.records | any(.id == "keyword-local" and .kind == "ship"))
      and (.backlog.records | any(.id == "shipping-scout" and .kind == "scout"))
  ' >/dev/null || failures="${failures}canonical or explicit task kind was lost; "
  json=$(run "$home" "$fakebin" --json --all-landed) \
    || fail "Bearings failed for captain-approved deliveries"
  [ "$created_kind" = captain ] \
    || failures="${failures}wrapper-created call kind was ${created_kind:-absent}; "
  printf '%s' "$json" | jq -e '.landed | any(.id == "answered-question") | not' >/dev/null \
    || failures="${failures}PR-naming captain answer was listed; "
  printf '%s' "$json" | jq -e '.landed | any(.id == "created-local-question") | not' >/dev/null \
    || failures="${failures}wrapper-created local answer was listed; "
  printf '%s' "$json" | jq -e '.landed | any(.id == "legacy-local-question") | not' >/dev/null \
    || failures="${failures}legacy kindless local answer was listed; "
  # At the base commit the generic Done-row selector publishes this PR-naming
  # row, so this exclusion assertion fails when the selector fix is absent.
  printf '%s' "$json" | jq -e '.landed | any(.id == "done-pr-nondelivery") | not' >/dev/null \
    || failures="${failures}non-merged PR row was listed; "
  # At the base commit a scout can fall through to its pull request, so this
  # exclusion assertion fails when report ownership is not enforced.
  printf '%s' "$json" | jq -e '.landed | any(.id == "scout-pr-no-report") | not' >/dev/null \
    || failures="${failures}reportless scout PR was listed; "
  # At the base commit a ship can fall through to a report path, so this
  # exclusion assertion fails when artifact-kind ownership is not enforced.
  printf '%s' "$json" | jq -e '.landed | any(.id == "ship-reported-path") | not' >/dev/null \
    || failures="${failures}reported ship row was listed; "
  # At the base commit pull-request links render ahead of report links, so this
  # artifact assertion fails by receiving report_pr instead of report_path.
  printf '%s' "$json" | jq -e --arg report_path "$report_path" \
    '.landed | any(.id == "reported-scout" and .artifact == $report_path)' >/dev/null \
    || failures="${failures}reported scout artifact was missing; "
  printf '%s' "$json" | jq -e \
    '.landed | any(.id == "local-delivery" and .artifact == "local main")' >/dev/null \
    || failures="${failures}local-only artifact was missing; "
  printf '%s' "$json" | jq -e --arg report "$keyword_report" \
    '.landed | any(.id == "keyword-scout" and .artifact == $report)' >/dev/null \
    || failures="${failures}canonical keyword scout was missing; "
  printf '%s' "$json" | jq -e \
    '.landed | any(.id == "keyword-local" and .artifact == "local main")' >/dev/null \
    || failures="${failures}canonical keyword local delivery was missing; "
  # tasks-axi records `done --note` as an indented body line, so this artifact
  # assertion fails whenever the note is read from the row title alone.
  printf '%s' "$json" | jq -e \
    '.landed | any(.id == "noted-local" and .artifact == "local main")' >/dev/null \
    || failures="${failures}recorded-note local delivery artifact was missing; "
  # A kindless row records the same landing, so reading the note from the body
  # must not cost it the section it reached while that note went unparsed.
  printf '%s' "$json" | jq -e \
    '.landed | any(.id == "legacy-noted-local" and .artifact == "local main")' >/dev/null \
    || failures="${failures}kindless local delivery was missing; "
  printf '%s' "$json" | jq -e --arg report "$shipping_report" \
    '.landed | any(.id == "shipping-scout" and .artifact == $report)' >/dev/null \
    || failures="${failures}longer-word explicit scout kind was lost; "
  [ -z "$failures" ] || fail "$failures$json"
  [ ! -s "$home/net.log" ] \
    || fail "kind-owned landed selection made a network call: $(cat "$home/net.log")"
  pass "landed accepts only kind-owned delivery artifacts while answered questions stay out"
}

test_kind_fallback_matches_tasks_axi_word_boundaries() {
  local home fakebin id title kind producer_kind fleet_json json
  [ -n "$TASKS_AXI_BIN" ] || fail "tasks-axi is required for the kind-boundary regression"
  fm_tasks_axi_compatible || {
    echo "skip: installed tasks-axi predates ${FM_TASKS_AXI_MIN}, so the real backlog mutations this regression needs are refused"
    return 0
  }
  home=$(make_home kind-word-boundaries)
  fakebin=$(make_fakebin "$home")
  : > "$home/net.log"
  : > "$home/expected.jsonl"
  while IFS='|' read -r id title kind; do
    "$TASKS_AXI_BIN" add "$id" "$title" --start --file "$home/data/backlog.md" >/dev/null \
      || fail "could not create keyword fixture $id"
    "$TASKS_AXI_BIN" 'done' "$id" --report "data/$id/report.md" \
      --file "$home/data/backlog.md" >/dev/null || fail "could not complete keyword fixture $id"
    producer_kind=$("$TASKS_AXI_BIN" show "$id" --full --file "$home/data/backlog.md" \
      | sed -n 's/^  kind: *//p' | head -1)
    [ "$producer_kind" = "${kind/-/task}" ] || fail "tasks-axi kind differs for $title: $producer_kind"
    jq -cn --arg id "$id" --arg kind "$kind" \
      '{id:$id,kind:(if $kind == "-" then null else $kind end)}' >> "$home/expected.jsonl"
  done <<'EOF'
scout-colon|SCOUT: investigate regression|scout
scout-unicode|SCOUTé investigate|scout
scout-longer|SCOUTING investigate|-
scout-underscore|SCOUT_investigate|-
scout-digit|SCOUT7 investigate|-
scout-lowercase|scout: investigate|-
scout-nonleading|Investigate SCOUT: regression|-
ship-colon|SHIP: implement|ship
ship-unicode|SHIPé implement|ship
ship-longer|SHIPPING implement|-
EOF
  fleet_json=$(PATH="$fakebin:$PATH" FM_HOME="$home" NET_LOG="$home/net.log" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) || fail "keyword fleet snapshot failed"
  printf '%s' "$fleet_json" | jq -e --slurpfile expected "$home/expected.jsonl" \
    '(.backlog.records | length) == ($expected | length)' >/dev/null \
    || fail "producer fixture rows were archived before comparison"
  printf '%s' "$fleet_json" | jq -e --slurpfile expected "$home/expected.jsonl" '
    (.backlog.records | map({id,kind}) | sort_by(.id)) == ($expected | sort_by(.id))
  ' >/dev/null || fail "snapshot kinds differ from tasks-axi word boundaries: $fleet_json"
  json=$(run "$home" "$fakebin" --json --all-landed) || fail "keyword bearings failed"
  printf '%s' "$json" | jq -e --slurpfile expected "$home/expected.jsonl" '
    (.landed | map({id,artifact}) | sort_by(.id)) ==
      ($expected | map(select(.kind == "scout") | {id,artifact:("data/" + .id + "/report.md")}) | sort_by(.id))
  ' >/dev/null || fail "keyword scout deliveries differ from producer kinds: $json"
  [ ! -s "$home/net.log" ] || fail "keyword projection made a network call"
  pass "kind fallback matches tasks-axi word boundaries and preserves scout deliveries"
}















# The roll-up stays bounded: a per-home cap and an overall cap, both disclosed in
# omitted[], with --all-landed as the counted expansion knob. This also covers the
# previously-silent main-home landed truncation.


# Bearings projects authoritative structured state rather than inventing return
# policy. A live blocked child remains a live in-flight record with state=blocked
# and an open blocker; it must never be converted into a queued `gates` record.
# The return-catch-up owner prevents this state from reaching ordinary rendering
# during an away return, while this test pins Bearings' own projection boundary.
test_live_blocker_is_not_charted_queue_work() {
  local home fakebin json
  home=$(make_home live-blocker); write_fixture "$home"
  printf 'blocked [key=synthetic-dependency]: firstmate can refresh the synthetic token\n' > "$home/state/ship-task.status"
  record_claude_state "$home/state" ship-task idle
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.[]; .id == "ship-task" and .state == "blocked"))
      and (.decisions_open | any(.[]; .id == "ship-task") | not)
      and (.gates | any(.[]; .id == "ship-task") | not)
  ' >/dev/null || fail "live blocked work was projected as queued/deferred work: $json"
  pass "Bearings keeps a live blocker in structured live state and never converts it to Charted Next queue work"
}

# Captain's Call is populated only from the durable keyed open-decision set. The
# anti-leak guard: action-free highlights - a working task, a completed scout,
# queued/gated items, landed work - must never surface as an open decision, so they
# cannot leak into Captain's Call. The standard fixture has exactly one genuine open
# decision (the secondmate's structured captain hold).
test_captains_call_anti_leak() {
  local home fakebin json canonical
  home=$(make_home anti-leak); write_fixture "$home"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  jq -n -e --argjson bearings "$json" --argjson canonical "$canonical" '
    ([$bearings.decisions_open[].id] == [])
      and ([$bearings.decisions_open[].id] | index("ship-task") | not)
      and ([$bearings.decisions_open[].id] | index("scout-x") | not)
      and ([$bearings.decisions_open[].id] | index("external-wait") | not)
      and ([$bearings.decisions_open[].id] | index("done-a") | not)
      and ([$bearings.decisions_open[].id] | index("mate-landed") | not)
      and ([$bearings.decisions_open[].id] | index("live-gate") | not)
      and ([$bearings.decisions_open[].id] | index("dead-gate") | not)
  ' >/dev/null || fail "only genuine open decisions may feed Captain's Call: $json"
  pass "action-free items (working/done/queued/landed) do not leak into Captain's Call"
}

# R1: main-home orphan in-flight and unstructured current rows must not vanish
# silently. Meta remains the sole live-work inventory; disclosure is via
# main_inventory + omitted[] + a Charted Next gate line, never fake Underway.
test_main_orphan_in_flight_is_disclosed_not_invented() {
  local home fakebin json canonical
  home=$(make_home main-orphan)
  : > "$home/data/secondmates.md"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] only-orphan - Structured in flight without meta (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued

## Done
EOF
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "in-flight backlog item has no child metadata"
      and (.main_inventory.orphan_in_flight == ["only-orphan"])
      and .main_inventory.unstructured_current_count == 0
      and (.tasks | length) == 0
  ' >/dev/null || fail "canonical main inventory missed orphan: $canonical"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | length) == 0
      and ([.in_flight[].id] | index("only-orphan") | not)
      and ([.decisions_open[].id] | index("only-orphan") | not)
      and (.gates | any(.id == "(main-inventory)"
        and (.title | contains("in-flight backlog item has no child metadata"))))
      and (.omitted | any(.surface == "main in-flight backlog item(s) have no child metadata: 1"))
  ' >/dev/null || fail "orphan in-flight was invented or not disclosed: $json"
  pass "main orphan in-flight stays out of Underway and is disclosed in omitted/gates"
}

test_main_unstructured_current_is_disclosed_with_structured_sibling() {
  local home fakebin json canonical
  home=$(make_home main-unstructured)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/structured-ship"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
this current row is not structured
- [ ] structured-ship - Visible structured sibling (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
another free-form note without checkbox
- [ ] structured-queued - Structured queued (repo: firstmate) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/structured-ship.meta" \
    "window=firstmate:fm-structured-ship" \
    "worktree=$home/projects/structured-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: structured sibling still projects\n' > "$home/state/structured-ship.status"
  fakebin=$(make_fakebin "$home")
  canonical=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json)
  printf '%s' "$canonical" | jq -e '
    .main_inventory.valid == false
      and .main_inventory.reason == "unstructured current backlog row"
      and .main_inventory.unstructured_current_count == 2
      and (.main_inventory.orphan_in_flight | length) == 0
  ' >/dev/null || fail "canonical main inventory missed unstructured current: $canonical"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] == ["structured-ship"])
      and ([.gates[].id] | index("structured-queued") != null)
      and (.gates | any(.id == "(main-inventory)"
        and (.title | contains("unstructured current backlog row"))))
      and (.omitted | any(.surface == "main unstructured current backlog row(s): 2"))
      and ([.decisions_open[].id] | index("(main-inventory)") | not)
  ' >/dev/null || fail "unstructured current not disclosed or structured sibling lost: $json"
  pass "main unstructured current is disclosed while structured siblings still project"
}

test_main_orphan_counterfactual_meta_clears_inventory_warning() {
  local home fakebin json_before json_after
  home=$(make_home main-orphan-counterfactual)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/orphan-ship"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] orphan-ship - Gains meta in counterfactual (repo: firstmate) (kind: ship) (since 2026-07-11)
- [ ] visible-ship - Already live (repo: firstmate) (kind: ship) (since 2026-07-11)

## Queued
- [ ] queued-ship - Ordinary queue (repo: firstmate) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/visible-ship.meta" \
    "window=firstmate:fm-visible-ship" \
    "worktree=$home/projects/orphan-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: visible sibling\n' > "$home/state/visible-ship.status"
  fakebin=$(make_fakebin "$home")
  json_before=$(run "$home" "$fakebin" --json)
  printf '%s' "$json_before" | jq -e '
    ([.in_flight[].id] == ["visible-ship"])
      and ([.in_flight[].id] | index("orphan-ship") | not)
      and (.omitted | any(.surface == "main in-flight backlog item(s) have no child metadata: 1"))
      and (.gates | any(.id == "(main-inventory)"))
      and ([.gates[].id] | index("queued-ship") != null)
  ' >/dev/null || fail "pre-meta orphan fixture failed: $json_before"
  fm_write_meta "$home/state/orphan-ship.meta" \
    "window=firstmate:fm-orphan-ship" \
    "worktree=$home/projects/orphan-ship" \
    "project=firstmate" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes"
  printf 'working: orphan now has meta\n' > "$home/state/orphan-ship.status"
  json_after=$(run "$home" "$fakebin" --json)
  printf '%s' "$json_after" | jq -e '
    ([.in_flight[].id] | sort) == ["orphan-ship", "visible-ship"]
      and ([.omitted[].surface] | any(test("main in-flight backlog item")) | not)
      and ([.gates[].id] | index("(main-inventory)") | not)
      and ([.decisions_open[].id] | index("orphan-ship") | not)
  ' >/dev/null || fail "adding meta did not clear inventory warning or project orphan: $json_after"
  pass "counterfactual meta clears main inventory warning and projects the live task"
}

seed_working_child() {  # <mate-home> <id> <doing> [repo]
  local mate=$1 id=$2 doing=$3 repo=${4-sample} repo_field=
  mkdir -p "$mate/projects/$id"
  [ -z "$repo" ] || repo_field=" (repo: $repo)"
  printf -- '- [ ] %s - %s%s (kind: ship) (since 2026-07-13)\n' \
    "$id" "$doing" "$repo_field" >> "$mate/data/backlog.md"
  fm_write_meta "$mate/state/$id.meta" \
    "window=firstmate:fm-$id" "worktree=$mate/projects/$id" "project=sample" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$mate/state" "$id" busy
  printf 'working: %s\n' "$doing" > "$mate/state/$id.status"
}

test_working_captain_holds_keep_their_bucket_surfaces() {
  local home mate fakebin id  json expanded
  home=$(make_home working-hold-buckets)
    cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] working-live - Working live call (repo: sample) (kind: captain) (hold: choose release route) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] working-live-two - Second working live call (repo: sample) (kind: captain) (hold: choose backup route) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] working-blocked - Working blocked call blocked-by: blocker-alpha-123456789012345678901234567890 blocked-by: blocker-beta-123456789012345678901234567890 (repo: sample) (kind: captain) (hold: choose blocked route) (hold-kind: captain)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] working-dated - Working dated call (repo: sample) (kind: captain) (hold: choose dated route) (hold-kind: captain) (hold-until: 2026-08-01)
  Captain hold set: 2026-07-10T00:00:00Z
- [ ] working-aged - Working aged call (repo: sample) (kind: captain) (hold: choose aged route) (hold-kind: captain)
  Captain hold set: 2026-06-01T00:00:00Z

## Queued

## Done
EOF
    for id in working-live working-live-two working-blocked working-dated working-aged; do
      mkdir -p "$home/projects/$id"
      fm_write_meta "$home/state/$id.meta" \
        "window=firstmate:fm-$id" "worktree=$home/projects/$id" "project=sample" \
        "harness=claude" "kind=ship" "mode=no-mistakes"
      record_claude_state "$home/state" "$id" busy
      printf 'working: active held work\n' > "$home/state/$id.status"
    done
  home=$(make_home working-hold-buckets)
  fakebin=$(make_fakebin "$home")

  json=$(FM_SNAPSHOT_SECONDMATE_DECISIONS=1 run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.in_flight[].id] | contains([
      "working-live", "working-live-two", "working-blocked", "working-dated", "working-aged"]))
      and (.decisions_open | any(.id == "working-live"))
      and (.decisions_open | any(.id == "working-live-two"))
      and ([.decisions_open[] | select(.id == "working-blocked" or .id == "working-dated" or .id == "working-aged")] | length) == 0
      and ([.gates[] | select(.id == "working-live" or .id == "working-live-two")] | length) == 0
      and ([.gates[] | select(.id == "working-blocked" and .owner == "(main)"
          and .blocked_by == "blocker-alpha-123456789012345678901234567890,blocker-beta-123456789012345678901234567890")] | length) == 1
      and ([.gates[] | select(.id == "working-dated" and .owner == "(main)" and (.reason | startswith("until 2026-08-01")))] | length) == 1
      and ([.gates[] | select(.id == "working-aged" and .owner == "(main)" and (.reason | startswith("held 40d")))] | length) == 1
  ' >/dev/null || fail "working captain holds did not surface in Underway and exactly one default decision bucket: $json"

  expanded=$(FM_SNAPSHOT_SECONDMATE_DECISIONS=1 run "$home" "$fakebin" --json --all-decisions --all-queued)
  printf '%s' "$expanded" | jq -e '
    ([.in_flight[].id] | contains([
      "working-live", "working-live-two", "working-blocked", "working-dated", "working-aged"]))
      and ([.decisions_open[].id]
        | contains(["working-live", "working-live-two", "working-blocked", "working-dated", "working-aged"]))
      and ([.decisions_open[] | select(
          (.id == "working-blocked")
          and (.summary | contains("blocked-by blocker-alpha-123456789012345678901234567890 +1 more"))
          and (.summary | length) <= 90)] | length) == 1
      and ([.gates[] | select(.id == "working-live" or .id == "working-live-two" or .id == "working-blocked"
          or .id == "working-dated" or .id == "working-aged")] | length) == 0
  ' >/dev/null || fail "--all-decisions did not keep working holds Underway and reveal each gate-free: $expanded"
  pass "working captain holds retain main and secondmate bucket surfaces"
}





test_newest_filed_gates_are_selected_before_snapshot_bounds() {
  local home mate fakebin json i
  home=$(make_home newest-before-bounds)
  : > "$home/data/secondmates.md"
  printf '## In flight\n\n## Queued\n' > "$home/data/backlog.md"
  i=1
  while [ "$i" -le 20 ]; do
    printf -- '- [ ] old-%02d - Older gate %02d (repo: sample) (kind: ship) (since 2026-06-%02d)\n' \
      "$i" "$i" "$i" >> "$home/data/backlog.md"
    i=$((i + 1))
  done
  printf -- '- [ ] newest - Newest gate (repo: sample) (kind: ship) (since 2026-07-01)\n\n## Done\n' \
    >> "$home/data/backlog.md"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.gates | length) == 20 and .gates[0].id == "newest"
      and (.gates | any(.id == "old-01") | not)
  ' >/dev/null || fail "the bearings gate bound dropped the newest filed row: $json"

  pass "newest filed gates are selected before snapshot bounds"
}

# A captain scanning Underway must be able to tell WHICH task a row is, and the
# board orders Charted Next by the durable filed date, so both facts have to come
# out of fleet state rather than being invented at render time.
test_underway_and_gate_rows_carry_the_durable_name_and_filed_date() {
  local home mate fakebin json
  home=$(make_home durable-name-filed)
  : > "$home/data/secondmates.md"
  mate="$TMP_ROOT/durable-name-home"
  mkdir -p "$home/projects/main-wt"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] main-ship - Rename the fleet board rows (repo: firstmate) (kind: ship) (since 2026-07-09)

## Queued
- [ ] newer-gate - Filed later (repo: firstmate) (kind: ship) (since 2026-07-10)
- [ ] older-gate - Filed earlier (repo: firstmate) (kind: ship) (since 2026-07-01)
- [ ] undated-gate - Filed before dates were recorded (repo: firstmate) (kind: ship)

## Done
EOF
  fm_write_meta "$home/state/main-ship.meta" \
    "window=firstmate:fm-main-ship" "worktree=$home/projects/main-wt" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes"
  record_claude_state "$home/state" main-ship busy
  printf 'working: no-mistakes review round 2\n' > "$home/state/main-ship.status"

  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.id == "main-ship"
      and .name == "Rename the fleet board rows"
      and (.doing | type == "string") and (.doing | length) > 0
      and .doing != .name))
      and (.gates | any(.id == "newer-gate" and .filed == "2026-07-10"))
      and (.gates | any(.id == "older-gate" and .filed == "2026-07-01"))
      and (.gates | any(.id == "undated-gate" and .filed == null))
  ' >/dev/null || fail "durable Underway names or gate filed dates are missing: $json"
  pass "Underway rows carry the durable task name and gates carry their filed date"
}



test_main_captain_readiness_matches_secondmate_projection() {
  local home fakebin json
  home=$(make_home main-captain-readiness)
  : > "$home/data/secondmates.md"
  mkdir -p "$home/projects/prep" "$home/projects/observation"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] observation - Held observation (repo: firstmate) (kind: scout) (hold: watch production) (hold-kind: external)
- [ ] prep - Prepare canary (repo: firstmate) (kind: ship)

## Queued
- [ ] review - Security review (repo: firstmate) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
EOF
  fm_write_meta "$home/state/prep.meta" \
    "window=firstmate:fm-prep" "worktree=$home/projects/prep" "project=firstmate" \
    "harness=codex" "kind=ship" "mode=no-mistakes"
  printf 'working: preparing main canary\n' > "$home/state/prep.status"
  fm_write_meta "$home/state/observation.meta" \
    "window=firstmate:fm-observation" "worktree=$home/projects/observation" "project=firstmate" \
    "harness=codex" "kind=scout" "mode=scout"
  printf 'paused: observation is deliberately held\n' > "$home/state/observation.status"
  fakebin=$(make_fakebin "$home")
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.in_flight | any(.id == "prep"))
      and (.in_flight | any(.id == "observation") | not)
      and ([.gates[] | select(.id == "observation" and .reason == "watch production")] | length) == 1
      and (.decisions_open | any(.id == "captain-run") | not)
      and (.gates | any(.id == "captain-run" and .blocked_by == "prep,review"))
  ' >/dev/null || fail "main blocked captain action or held-child projection was wrong: $json"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] review - Security review (repo: firstmate) (kind: ship)
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: firstmate) (kind: ship) (done 2026-07-22)
EOF
  rm "$home/state/prep.meta" "$home/state/prep.status" \
    "$home/state/observation.meta" "$home/state/observation.status"
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    (.decisions_open | any(.id == "captain-run") | not)
      and (.gates | any(.id == "captain-run" and .blocked_by == "review"))
  ' >/dev/null || fail "main one-blocker captain action became premature: $json"

  cat > "$home/data/backlog.md" <<'EOF'
## In flight

## Queued
- [ ] captain-run - Run captain canary blocked-by: prep blocked-by: review (repo: firstmate) (kind: captain) (hold: captain runs canary) (hold-kind: captain)

## Done
- [x] prep - Prepare canary (repo: firstmate) (kind: ship) (done 2026-07-22)
- [x] review - Security review (repo: firstmate) (kind: ship) (done 2026-07-22)
EOF
  json=$(run "$home" "$fakebin" --json)
  printf '%s' "$json" | jq -e '
    ([.decisions_open[] | select(.id == "captain-run")] | length) == 1
      and (.gates | any(.id == "captain-run") | not)
  ' >/dev/null || fail "main zero-blocker captain action was not projected exactly once: $json"
  pass "main and secondmate captain actionability use the same blocker readiness"
}

test_task_teardown_during_metadata_capture_does_not_abort_snapshot() {
  local home fakebin real_cp output snapshot_pid i
  home=$(make_home metadata-teardown-race)
  fakebin=$(make_fakebin "$home")
  real_cp=$(command -v cp)
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] a-hold - Stable local worker (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/a-hold.meta" \
    "window=fixture:a-hold" "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
  fm_write_meta "$home/state/z-gone.meta" \
    "window=fixture:z-gone" "project=firstmate" "harness=claude" "kind=ship" "mode=no-mistakes"
  printf 'working: stable fixture\n' > "$home/state/a-hold.status"
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  case "$arg" in
    */a-hold.meta)
      : > "$FAKE_CP_STARTED"
      while [ ! -e "$FAKE_CP_RELEASE" ]; do sleep 0.01; done
      break
      ;;
  esac
done
exec "$REAL_CP" "$@"
SH
  chmod +x "$fakebin/cp"

  REAL_CP="$real_cp" FAKE_CP_STARTED="$home/cp-started" FAKE_CP_RELEASE="$home/cp-release" \
    run "$home" "$fakebin" --json > "$home/snapshot.json" &
  snapshot_pid=$!
  i=0
  while [ ! -e "$home/cp-started" ] && [ "$i" -lt 500 ]; do
    sleep 0.01
    i=$((i + 1))
  done
  if [ ! -e "$home/cp-started" ]; then
    kill "$snapshot_pid" 2>/dev/null || true
    wait "$snapshot_pid" 2>/dev/null || true
    fail "snapshot never entered metadata capture"
  fi
  rm -f "$home/state/z-gone.meta"
  : > "$home/cp-release"
  wait "$snapshot_pid" || fail "task teardown aborted the public Bearings snapshot"
  output=$(<"$home/snapshot.json")
  printf '%s' "$output" | jq -e '
    .schema == "fm-bearings.v1"
      and ([.in_flight[].id] | sort) == ["a-hold"]
  ' >/dev/null || fail "snapshot after concurrent teardown was not usable: $output"
  pass "task teardown during metadata capture is omitted without aborting the snapshot"
}

test_current_state_uses_captured_status_observation() {
  local home fakebin real_cp worktree json
  home=$(make_home captured-status-race)
  fakebin=$(make_fakebin "$home")
  real_cp=$(command -v cp)
  worktree="$home/projects/captured-status"
  mkdir -p "$worktree"
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] captured-status - Captured status fixture (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/captured-status.meta" \
    "window=fixture:captured-status" "worktree=$worktree" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=stable-generation"
  printf 'working: captured state\n' > "$home/state/captured-status.status"
  record_claude_state "$home/state" captured-status idle
  cat > "$fakebin/cp" <<'SH'
#!/usr/bin/env bash
"$REAL_CP" "$@" || exit
for arg in "$@"; do
  if [ "$arg" = "$RACE_STATUS" ] && mkdir "$RACE_ONCE" 2>/dev/null; then
    printf 'needs-decision[new]: appended after capture\n' >> "$RACE_STATUS"
    break
  fi
done
SH
  chmod +x "$fakebin/cp"

  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_NOW_EPOCH=1783792800 NET_LOG="$home/net.log" REAL_CP="$real_cp" \
    RACE_ONCE="$home/status-race-once" RACE_STATUS="$home/state/captured-status.status" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot failed during captured status race"
  printf '%s' "$json" | jq -e '
    .tasks[] | select(.id == "captured-status")
    | .current_state.state == "working"
      and .current_state.source == "status-log"
      and .paths.status_log.last_event.raw == "working: captured state"
      and .hints.pending_decision == false
      and .hints.open_decisions == []
  ' >/dev/null || fail "current state escaped the captured status observation: $json"
  [ "$(tail -n 1 "$home/state/captured-status.status")" = \
      "needs-decision[new]: appended after capture" ] \
    || fail "captured status race fixture did not append the live decision"
  pass "current state and decision hints share one captured status observation"
}

test_relaunched_task_does_not_inherit_reused_endpoint_state() {
  local home fakebin worktree json
  home=$(make_home endpoint-generation-race)
  worktree="$home/projects/generation-race-not-created"
  fakebin=$(make_fakebin "$home")
  cat > "$home/data/backlog.md" <<'EOF'
## In flight
- [ ] generation-race - Generation identity fixture (repo: firstmate) (kind: ship)

## Queued

## Done
EOF
  fm_write_meta "$home/state/generation-race.meta" \
    "window=fixture:fm-generation-race" "worktree=$worktree" "project=firstmate" \
    "harness=claude" "kind=ship" "mode=no-mistakes" "spawn_gen=old-generation"
  printf 'working: old generation\n' > "$home/state/generation-race.status"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
if [ "${1:-}" = display-message ]; then
  if mkdir "$RACE_ONCE" 2>/dev/null; then
    tmp="$RACE_META.tmp.$$"
    cat > "$tmp" <<EOF
window=fixture:fm-generation-race
worktree=$RACE_WORKTREE
project=firstmate
harness=claude
kind=ship
mode=no-mistakes
spawn_gen=new-generation
EOF
    mv "$tmp" "$RACE_META"
    printf 'needs-decision[replacement]: replacement-only decision https://github.com/acme/firstmate/pull/999\n' > "$RACE_STATUS"
    mkdir -p "$(dirname "$RACE_REPORT")"
    printf 'replacement-only report\n' > "$RACE_REPORT"
  fi
  # The old endpoint disappeared while a replacement reused the same target.
  exit 1
fi
exit 0
SH
  chmod +x "$fakebin/tmux"

  json=$(PATH="$fakebin:$PATH" FM_HOME="$home" FM_SNAPSHOT_NOW=2026-07-11T18:00:00Z \
    FM_SNAPSHOT_NOW_EPOCH=1783792800 NET_LOG="$home/net.log" \
    RACE_ONCE="$home/relaunch-once" RACE_META="$home/state/generation-race.meta" \
    RACE_STATUS="$home/state/generation-race.status" \
    RACE_REPORT="$home/data/generation-race/report.md" RACE_WORKTREE="$worktree" \
    "$ROOT/bin/fm-fleet-snapshot.sh" --json) \
    || fail "fleet snapshot failed during endpoint generation race"
  printf '%s' "$json" | jq -e '
    .tasks[] | select(.id == "generation-race")
    | .spawn_gen == "old-generation"
      and .current_state.state == "unknown"
      and .endpoint.exists == null
      and .endpoint.agent_alive == "unknown"
      and .endpoint.status == "unknown"
      and .pr.url == null
      and .paths.status_log.present == false
      and .paths.report.present == false
      and .hints.pending_decision == false
      and .hints.open_decisions == []
      and .hints.scout_report_present == false
      and .hints.last_event_text == ""
  ' >/dev/null || fail "replacement live state crossed task generations: $json"
  pass "reused live state is discarded when task generation changes"
}

test_large_local_snapshot_overlaps_local_reads_without_projection_drift() {
  local home fakebin worktree serial parallel parallel_file snapshot_pid i
  local serial_started serial_elapsed parallel_started parallel_elapsed saved
  home=$(make_home large-local-snapshot)
  worktree="$home/projects/shared-worktree"
  fm_git_init_commit "$worktree"
  git -C "$worktree" checkout -qb fm/synthetic-large-local
  fakebin=$(make_fakebin "$home")
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
if [ "$*" = "axi status" ] && [ "${FAKE_NM_DELAY:-0}" = 1 ]; then
  [ -z "${FAKE_NM_SIGNAL:-}" ] || : > "$FAKE_NM_SIGNAL"
  sleep 1
fi
exit 0
SH
  chmod +x "$fakebin/no-mistakes"

  {
    printf '## In flight\n'
    i=1
    while [ "$i" -le 5 ]; do
      printf -- '- [ ] local-%s - Synthetic local worker %s (repo: firstmate) (kind: ship)\n' "$i" "$i"
      i=$((i + 1))
    done
    printf '\n## Queued\n\n## Done\n'
    i=1
    while [ "$i" -le 300 ]; do
      printf -- '- [x] history-%s - Historical completed item %s https://github.com/acme/firstmate/pull/%s (repo: firstmate) (kind: ship) (done 2026-01-01)\n' "$i" "$i" "$i"
      i=$((i + 1))
    done
  } > "$home/data/backlog.md"
  i=1
  while [ "$i" -le 5 ]; do
    fm_write_meta "$home/state/local-$i.meta" \
      "window=fixture:local-$i" "worktree=$worktree" "project=firstmate" \
      "harness=claude" "kind=ship" "mode=no-mistakes"
    printf 'working: synthetic fixture\n' > "$home/state/local-$i.status"
    i=$((i + 1))
  done

  serial=$(FAKE_NM_DELAY=0 FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 run "$home" "$fakebin" --json)

  # Serialized reads pay every worker's delay end to end while concurrent reads
  # overlap them. Time both runs and compare, because the two pay the same
  # composition overhead: the difference isolates the overlap this change
  # delivers, where an absolute wall-clock budget would instead measure how
  # loaded the host happens to be and flake on a busy runner.
  serial_started=$(date +%s)
  FAKE_NM_DELAY=1 FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=1 \
    run "$home" "$fakebin" --json >/dev/null \
    || fail "serialized local snapshot failed"
  serial_elapsed=$(( $(date +%s) - serial_started ))

  parallel_started=$(date +%s)
  parallel_file="$home/parallel-snapshot.json"
  FAKE_NM_DELAY=1 FAKE_NM_SIGNAL="$home/nm-started" \
    FM_SNAPSHOT_LOCAL_READ_CONCURRENCY=8 \
    run "$home" "$fakebin" --json > "$parallel_file" &
  snapshot_pid=$!
  i=0
  while [ ! -e "$home/nm-started" ] && [ "$i" -lt 100 ]; do
    sleep 0.05
    i=$((i + 1))
  done
  if [ ! -e "$home/nm-started" ]; then
    kill "$snapshot_pid" 2>/dev/null || true
    wait "$snapshot_pid" 2>/dev/null || true
    fail "concurrent local snapshot never began a current-state read"
  fi
  wait "$snapshot_pid" || fail "concurrent local snapshot failed"
  parallel=$(<"$parallel_file")
  parallel_elapsed=$(( $(date +%s) - parallel_started ))
  # Five one-second reads serialize into five seconds and overlap into about
  # one, so at least two of those four seconds must show up as real savings.
  # Serializing the reads again collapses that difference to roughly zero.
  saved=$(( serial_elapsed - parallel_elapsed ))
  [ "$saved" -ge 2 ] \
    || fail "concurrent local reads saved no measurable time (serial ${serial_elapsed}s vs concurrent ${parallel_elapsed}s)"
  [ "$parallel" = "$serial" ] \
    || fail "concurrent local observation changed the fm-bearings.v1 projection"
  printf '%s' "$parallel" | jq -e '
    .schema == "fm-bearings.v1"
      and (.in_flight | length) == 5
      and ([.in_flight[].id] | sort) == ["local-1","local-2","local-3","local-4","local-5"]
      and ([.in_flight[] | select(.id == "local-1" and .kind == "ship")] | length) == 1
  ' >/dev/null || fail "large local snapshot lost a worker row: $parallel"
  pass "large local snapshot overlaps local reads with byte-identical serial and concurrent projections"
}





test_task_teardown_during_metadata_capture_does_not_abort_snapshot
test_current_state_uses_captured_status_observation
test_relaunched_task_does_not_inherit_reused_endpoint_state
test_large_local_snapshot_overlaps_local_reads_without_projection_drift
test_current_landed_baseline_is_repeatable_and_prior_report_independent
test_default_is_bounded_and_local_only
test_toon_json_parity
test_landed_accepts_only_kind_owned_delivery_artifacts
test_kind_fallback_matches_tasks_axi_word_boundaries
test_live_blocker_is_not_charted_queue_work
test_captains_call_anti_leak
test_main_orphan_in_flight_is_disclosed_not_invented
test_main_unstructured_current_is_disclosed_with_structured_sibling
test_main_orphan_counterfactual_meta_clears_inventory_warning
test_working_captain_holds_keep_their_bucket_surfaces
test_newest_filed_gates_are_selected_before_snapshot_bounds
test_underway_and_gate_rows_carry_the_durable_name_and_filed_date
test_main_captain_readiness_matches_secondmate_projection
test_completed_scout_report_not_pending
test_report_pointers_surface
test_queued_item_prose_never_hides_it
test_include_prs_is_the_only_fetch_path
test_include_prs_maps_custom_branch_prefix_to_task
test_partial_github_failure_degrades
test_perl_fallback_bounds_github_call
test_section_caps_and_expansion_flags
test_collapsed_captain_call_deferral_and_landed
test_undated_hold_phrasing_and_aging_projection
test_blocked_deferred_hold_has_concrete_disclosure
test_revealed_deferred_holds_show_their_deferral_reason
test_pr_repository_cap_and_expansion
test_per_repository_pr_cap_is_disclosed
test_projection_and_toon_fail_closed
