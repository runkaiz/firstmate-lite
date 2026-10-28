#!/usr/bin/env bash
# Live attached-viewer regression for the Herdr teardown focus guard.
#
# PR #4131 gated the active-tab close refusal on a LIVE foreground client
# instead of the persisted `.focused` pointer, but only its two detached
# scenarios could be driven live: every pseudo-terminal the runner built
# started at a zero-sized window grid, so Herdr registered no foreground client
# and `terminal title clear` kept answering `no_foreground_client`. That was a
# harness limit, not a product one. `fm-herdr-lab.sh viewer start` now attaches
# a real Herdr TUI over a pty sized before the fork, which turns those
# untestable cases into this regression:
#
#   3. a viewer sitting on the target tab blocks the close;
#   4. a viewer that moves ONTO the target between planning and the mutation
#      boundary still blocks it, because the guard re-reads focus there;
#   5. a viewer that moves OFF the target instead keeps its fresh non-target
#      focus after the close, rather than being dragged back to a stale
#      pre-planning pointer;
#   7. the projection's seeded-tab prune inherits the same refusal.
#
# Scenarios 4 and 5 need a focus change at one exact product boundary, so a
# PATH shim performs the real `tab focus` when the close helper issues its
# planning `pane get`. Every Herdr call, the shim's included, still routes
# through the guarded lab helper against a named non-default session.
#
# The guard submits no model prompts, so the shared live gate runs it wherever
# herdr, jq, and python3 exist. Re-run it after every Herdr upgrade: a release
# that changed the foreground-client contract would surface here first.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

LAB_HELPER=${HERDR_LAB_HELPER:-$ROOT/bin/fm-herdr-lab.sh}
LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}

fm_live_gate default-on FM_HERDR_ATTACHED_VIEWER_LIVE_E2E herdr jq python3 treehouse

[ -x "$LAB_HELPER" ] || { echo "skip: Herdr lab helper not executable at $LAB_HELPER"; exit 0; }

TMP_ROOT=$(fm_test_tmproot fm-herdr-attached-viewer)
FAKEBIN=$(fm_fakebin "$TMP_ROOT")
FOCUS_SWITCH_CONTROL="$TMP_ROOT/focus-switch"
ORIGINAL_PATH=$PATH
LAB_SESSION=$("$LAB_HELPER" name fm-herdr-attached-viewer)
export LAB_HELPER LAB_SESSION ORIGINAL_PATH FOCUS_SWITCH_CONTROL
SPAWN_FIXTURE_ROOT=
SPAWN_FIXTURE_HOME=

cleanup() {
  local status=$?
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" viewer stop "$LAB_SESSION" >/dev/null 2>&1 || status=1
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" teardown "$LAB_SESSION" || status=1
  if [ -n "$SPAWN_FIXTURE_ROOT" ]; then
    # Only this test's fixture pool, after its named terminal session stopped.
    while IFS= read -r marker; do
      slot=${marker%/.git}
      common=$(git -C "$slot" rev-parse --path-format=absolute --git-common-dir) || { status=1; continue; }
      [ "$common" = "$SPAWN_FIXTURE_ROOT/project/.git" ] || { status=1; continue; }
      treehouse --root "$SPAWN_FIXTURE_ROOT" return "$slot" || status=1
    done < <(find "$SPAWN_FIXTURE_ROOT/.treehouse" -type f -name .git 2>/dev/null)
    "$LAB_HOME_HELPER" teardown "$SPAWN_FIXTURE_HOME" || status=1
  fi
  fm_test_cleanup
  exit "$status"
}
trap cleanup EXIT
"$LAB_HELPER" provision "$LAB_SESSION" || fail "could not provision the isolated Herdr lab"

lab() { env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"; }

# The adapter under test calls `herdr` by name. This shim strips the trailing
# session flag the helper will re-append, refuses any caller-supplied one, and
# optionally performs one real focus change at the requested product boundary
# before forwarding the call.
cat > "$FAKEBIN/herdr" <<'SH'
#!/usr/bin/env bash
set -u
args=("$@")
last=$((${#args[@]} - 1))
flag=$((last - 1))
if [ "${#args[@]}" -ge 2 ] \
  && [ "${args[$flag]}" = --session ] \
  && [ "${args[$last]}" = "$LAB_SESSION" ]; then
  unset "args[$last]" "args[$flag]"
fi
set -- "${args[@]}"
for arg in "$@"; do
  case "$arg" in --session|--session=*) exit 9 ;; esac
done
# Keep shell startup's PATH changes from redirecting the fixture to a host pool.
# Only the task's explicit one-shot command is replaced with its private shim.
if [ -n "${FM_HERDR_FIXTURE_TREEHOUSE:-}" ] && [ "${1:-} ${2:-}" = 'pane run' ]; then
  args[3]=${args[3]//treehouse get/"'$FM_HERDR_FIXTURE_TREEHOUSE' get"}
  set -- "${args[@]}"
fi
if [ -f "$FOCUS_SWITCH_CONTROL/trigger" ] && [ "$*" = "$(cat "$FOCUS_SWITCH_CONTROL/trigger")" ]; then
  rm -f "$FOCUS_SWITCH_CONTROL/trigger"
  env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" \
    tab focus "$(cat "$FOCUS_SWITCH_CONTROL/tab")" >/dev/null 2>&1
  printf '%s\n' switched > "$FOCUS_SWITCH_CONTROL/done"
fi
exec env PATH="$ORIGINAL_PATH" "$LAB_HELPER" run "$LAB_SESSION" "$@"
SH
chmod +x "$FAKEBIN/herdr"

mkdir -p "$FOCUS_SWITCH_CONTROL"

# Arm the shim to run `tab focus <tab>` immediately before the adapter's own
# `pane get <pane>` planning read, which is the last product call before the
# close helper re-reads focus at its mutation boundary.
arm_focus_switch() { # <tab-id> <pane-id>
  rm -f "$FOCUS_SWITCH_CONTROL/done"
  printf '%s\n' "$1" > "$FOCUS_SWITCH_CONTROL/tab"
  printf 'pane get %s\n' "$2" > "$FOCUS_SWITCH_CONTROL/trigger"
}

assert_focus_switch_fired() { # <label>
  [ -f "$FOCUS_SWITCH_CONTROL/done" ] \
    || fail "$1: the mid-close focus switch never ran, so the timing boundary was not exercised"
  rm -f "$FOCUS_SWITCH_CONTROL/done" "$FOCUS_SWITCH_CONTROL/trigger"
}

# Drive one real adapter entry point with the shim on PATH.
drive() { # <function> <argument...>
  PATH="$FAKEBIN:$ORIGINAL_PATH" bash -c '
    . "$1/bin/backends/herdr.sh"
    fm_backend_herdr_cli() {
      local session=$1
      shift
      HERDR_SESSION="$session" herdr "$@" --session "$session"
    }
    fn=$2
    shift 2
    "$fn" "$@"
  ' _ "$ROOT" "$@" 2>&1
}

# These run inside command substitutions, where `fail` would exit only the
# subshell and let the script carry on with empty ids. They return non-zero
# instead, and every call site carries its own `|| fail`.
new_workspace() { # <label> -> "<workspace>\t<tab>\t<pane>"
  local out
  out=$(lab workspace create --cwd "$ROOT" --label "$1" --no-focus) || return 1
  printf '%s' "$out" | jq -er '
    [.result.workspace.workspace_id, .result.tab.tab_id, .result.root_pane.pane_id] | @tsv
  '
}

new_tab() { # <workspace> <label> -> "<tab>\t<pane>"
  local out
  out=$(lab tab create --workspace "$1" --label "$2" --cwd "$ROOT") || return 1
  printf '%s' "$out" | jq -er '[.result.tab.tab_id, .result.root_pane.pane_id] | @tsv'
}

focused_tab() {
  lab workspace list | jq -er '
    [.result.workspaces[] | select(.focused == true)] | select(length == 1) | .[0].active_tab_id
  '
}

pane_exists() { lab pane get "$1" >/dev/null 2>&1; }

foreground_reason() {
  lab terminal title clear | jq -er '.result.reason'
}

# --- the attachment itself, which is what #4131 could not do ----------------

REASON=$(foreground_reason) || fail "could not probe the session's foreground client"
[ "$REASON" = no_foreground_client ] \
  || fail "the fresh lab already had a foreground client (reason=$REASON)"

"$LAB_HELPER" viewer start "$LAB_SESSION" >/dev/null \
  || fail "could not attach a real foreground Herdr viewer over a sized pty"
REASON=$(foreground_reason) || fail "could not probe the session's foreground client"
[ "$REASON" = cleared ] \
  || fail "the attached pty viewer did not register as a foreground client (reason=$REASON)"
CLIENT_VERSION=$(lab status --json | jq -r '.client.version // "unknown"')
printf '# runtime: herdr=%s treehouse=%s\n' "$CLIENT_VERSION" "$(treehouse --version)"
pass "attached viewer: a pty sized before the fork registers as a real Herdr foreground client"

# A fresh tab can echo input while shell startup still consumes it. Prove an
# execution acknowledgement on the real attached terminal before a one-shot
# preparation command; the command's append is an independent exactly-once
# oracle, not a screen match of echoed input. No agent or Git network access.
FIXTURE=$(new_workspace shell-readiness) || fail "could not create shell-readiness workspace"
IFS=$'\t' read -r READY_WORKSPACE _ _ <<<"$FIXTURE"
for attempt in 1 2 3; do
  FIXTURE=$(new_tab "$READY_WORKSPACE" "shell-readiness-$attempt") || fail "could not create fresh readiness tab"
  IFS=$'\t' read -r _ READY_PANE <<<"$FIXTURE"
  READY_LOG="$TMP_ROOT/preparation-$attempt"
  OUT=$(drive fm_backend_herdr_prepare_shell "$LAB_SESSION:$READY_PANE" "printf 'prepared\\n' >> '$READY_LOG'")
  STATUS=$?
  [ "$STATUS" -eq 0 ] || fail "fresh shell readiness failed: $OUT"
  for _ in $(seq 1 30); do
    [ ! -s "$READY_LOG" ] || break
    sleep 0.1
  done
  [ -f "$READY_LOG" ] || fail "acknowledged shell did not execute preparation"
  [ "$(cat "$READY_LOG")" = prepared ] || fail "preparation did not execute exactly once"
done
pass "attached viewer: fresh shells acknowledge execution before one-shot preparation"

# Exercise the whole allocation/isolation boundary, using only a local-file
# origin, a task-private pool and marker workers. An occupied pool must report
# the allocator's exit and diagnostic, rather than spending the cwd timeout.
SPAWN_FIXTURE_ROOT="$TMP_ROOT/spawn-fixture"
SPAWN_FIXTURE_HOME="$SPAWN_FIXTURE_ROOT/home"
PROBE_TMP="$SPAWN_FIXTURE_ROOT/probe tmp's"
"$LAB_HOME_HELPER" create "$SPAWN_FIXTURE_HOME" >/dev/null || fail "could not mark fixture home"
mkdir -p "$SPAWN_FIXTURE_ROOT/project" "$PROBE_TMP"
git -C "$SPAWN_FIXTURE_ROOT/project" init -q -b main || fail "could not initialize fixture"
printf 'fixture\n' > "$SPAWN_FIXTURE_ROOT/project/README.md"
printf 'max_trees = 1\nroot = "%s"\n' "$SPAWN_FIXTURE_ROOT" > "$SPAWN_FIXTURE_ROOT/project/treehouse.toml"
git -C "$SPAWN_FIXTURE_ROOT/project" add . || fail "could not stage fixture"
git -C "$SPAWN_FIXTURE_ROOT/project" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid \
  commit -qm fixture || fail "could not commit fixture"
git clone -q --bare "$SPAWN_FIXTURE_ROOT/project" "$SPAWN_FIXTURE_ROOT/origin.git" || fail "could not create local origin"
git -C "$SPAWN_FIXTURE_ROOT/project" remote add origin "file://$SPAWN_FIXTURE_ROOT/origin.git" || fail "could not bind local origin"
printf 'off\n' > "$SPAWN_FIXTURE_HOME/config/herdr-presentation-spaces"
printf 'manual\n' > "$SPAWN_FIXTURE_HOME/config/backlog-backend"
export FM_HERDR_FIXTURE_TREEHOUSE="$SPAWN_FIXTURE_ROOT/treehouse"
{
  printf '#!/usr/bin/env bash\nset -eu\n'
  printf 'fixture=%q\nreal=%q\n' "$SPAWN_FIXTURE_ROOT" "$(command -v treehouse)"
  cat <<'SH'
[ "$(pwd -P)" = "$fixture/project" ] || exit 91
printf '%s\n' "$*" >> "$fixture/allocations"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false
exec "$real" --root "$fixture" "$@"
SH
} > "$FM_HERDR_FIXTURE_TREEHOUSE"
chmod +x "$FM_HERDR_FIXTURE_TREEHOUSE"

for admission in free occupied; do
  ID="attached-alloc-$admission-$$"
  mkdir -p "$SPAWN_FIXTURE_HOME/data/$ID"
  cat > "$SPAWN_FIXTURE_HOME/data/$ID/brief.md" <<'MD'
# Task
## Captain's intent
Verify the isolated fixture launch boundary.

## Firstmate spec
Write only the harmless worker cwd marker.
MD
  MARKER="$SPAWN_FIXTURE_ROOT/worker-$admission"
  # The positional parameter belongs to the generated marker worker.
  # shellcheck disable=SC2016
  printf -v RAW_WORKER 'bash -c '\''pwd -P > "$1"'\'' _ %q' "$MARKER"
  START=$SECONDS
  OUT=$(env -u HERDR_ENV -u HERDR_PANE_ID -u HERDR_TAB_ID -u HERDR_WORKSPACE_ID -u HERDR_SOCKET_PATH \
    -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE \
    PATH="$FAKEBIN:$ORIGINAL_PATH" HERDR_SESSION="$LAB_SESSION" \
    TMPDIR="$PROBE_TMP" \
    FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$SPAWN_FIXTURE_HOME" FM_SPAWN_NO_GUARD=1 \
    GIT_TERMINAL_PROMPT=0 GIT_ASKPASS=/bin/false SSH_ASKPASS=/bin/false \
    bash "$ROOT/bin/fm-spawn.sh" "$ID" "$SPAWN_FIXTURE_ROOT/project" "$RAW_WORKER" --scout --backend herdr 2>&1)
  STATUS=$?
  ELAPSED=$((SECONDS - START))
  [ -z "$(find "$PROBE_TMP" -name 'fm-allocation.*' -o -name 'fm-herdr-ready.*')" ] \
    || fail "spawn leaked its allocation/readiness acknowledgement directory"
  case "$admission" in
    free)
      [ "$STATUS" = 0 ] || fail "free private-pool launch failed: $OUT"
      for _ in $(seq 1 30); do [ ! -s "$MARKER" ] || break; sleep 0.1; done
      [ -s "$MARKER" ] || fail "isolated marker worker never executed"
      WT=$(sed -n 's/^worktree=//p' "$SPAWN_FIXTURE_HOME/state/$ID.meta")
      [ "$(cat "$MARKER")" = "$WT" ] || fail "worker cwd differs from recorded copy"
      case "$WT" in "$SPAWN_FIXTURE_ROOT/.treehouse/"*) ;; *) fail "allocation escaped private fixture: $WT" ;; esac
      [ "$WT" != "$SPAWN_FIXTURE_ROOT/project" ] || fail "worker ran in primary"
      [ "$(cat "$SPAWN_FIXTURE_ROOT/allocations")" = get ] || fail "free launch allocated more than once"
      ;;
    occupied)
      [ "$STATUS" != 0 ] || fail "occupied private pool incorrectly launched"
      assert_contains "$OUT" 'treehouse get exited with status 1' "allocator completion was masked: $OUT"
      assert_contains "$OUT" 'all 1 worktrees are in use or dirty' "allocator diagnostic was lost: $OUT"
      [ "$ELAPSED" -lt 60 ] || fail "known allocator refusal still spent the isolation timeout"
      [ ! -e "$MARKER" ] && [ ! -e "$SPAWN_FIXTURE_HOME/state/$ID.meta" ] || fail "refused launch started or published a worker"
      [ "$(wc -l < "$SPAWN_FIXTURE_ROOT/allocations" | tr -d ' ')" = 2 ] || fail "occupied launch retried allocation"
      ;;
  esac
done
unset FM_HERDR_FIXTURE_TREEHOUSE
pass "attached viewer: real spawn allocates once in a private copy and reports allocator refusal before the isolation timeout"

# --- scenario 3: a viewer on the target tab blocks the close ---------------

FIXTURE=$(new_workspace viewer-active) || fail "could not create the scenario 3 workspace"
IFS=$'\t' read -r WS_THREE TAB_THREE_A PANE_THREE_A <<<"$FIXTURE"
# A second tab keeps the close a plain one rather than an emptying-workspace plan.
new_tab "$WS_THREE" viewer-active-b >/dev/null || fail "could not create the scenario 3 companion tab"
lab tab focus "$TAB_THREE_A" >/dev/null || fail "could not focus the scenario 3 target tab"
[ "$(focused_tab)" = "$TAB_THREE_A" ] || fail "scenario 3 did not start focused on the target tab"

OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_THREE_A")
STATUS=$?
[ "$STATUS" -ne 0 ] || fail "a live viewer on the target tab did not block the close: $OUT"
assert_contains "$OUT" "target is the captain's active tab" \
  "the live-viewer refusal did not name the captain's active tab: $OUT"
pane_exists "$PANE_THREE_A" \
  || fail "the close proceeded and destroyed the tab the live viewer was watching"
pass "attached viewer: a live client on the target tab refuses the close and keeps the pane"

# --- scenario 4: the viewer moves ONTO the target mid-close ----------------

FIXTURE=$(new_workspace viewer-late-on) || fail "could not create the scenario 4 workspace"
IFS=$'\t' read -r WS_FOUR TAB_FOUR_A PANE_FOUR_A <<<"$FIXTURE"
FIXTURE=$(new_tab "$WS_FOUR" viewer-late-on-b) || fail "could not create the scenario 4 companion tab"
IFS=$'\t' read -r TAB_FOUR_B _ <<<"$FIXTURE"
lab tab focus "$TAB_FOUR_B" >/dev/null || fail "could not focus away from the scenario 4 target"
[ "$(focused_tab)" = "$TAB_FOUR_B" ] || fail "scenario 4 did not start focused off the target tab"

arm_focus_switch "$TAB_FOUR_A" "$PANE_FOUR_A"
OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_FOUR_A")
STATUS=$?
assert_focus_switch_fired "scenario 4"
[ "$STATUS" -ne 0 ] \
  || fail "a viewer that moved onto the target after planning did not block the close: $OUT"
assert_contains "$OUT" "target is the captain's active tab" \
  "the late-switch refusal did not come from the fresh active-tab check: $OUT"
pane_exists "$PANE_FOUR_A" \
  || fail "the close destroyed a tab the viewer had moved onto before the mutation boundary"
pass "attached viewer: focus moving onto the target between planning and mutation still blocks the close"

# --- scenario 5: the viewer moves OFF the target mid-close -----------------

FIXTURE=$(new_workspace viewer-late-off) || fail "could not create the scenario 5 workspace"
IFS=$'\t' read -r WS_FIVE TAB_FIVE_A PANE_FIVE_A <<<"$FIXTURE"
FIXTURE=$(new_tab "$WS_FIVE" viewer-late-off-b) || fail "could not create the scenario 5 companion tab"
IFS=$'\t' read -r TAB_FIVE_B _ <<<"$FIXTURE"
lab tab focus "$TAB_FIVE_A" >/dev/null || fail "could not focus the scenario 5 target tab"
[ "$(focused_tab)" = "$TAB_FIVE_A" ] || fail "scenario 5 did not start focused on the target tab"

arm_focus_switch "$TAB_FIVE_B" "$PANE_FIVE_A"
OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_FIVE_A")
STATUS=$?
assert_focus_switch_fired "scenario 5"
[ "$STATUS" -eq 0 ] \
  || fail "the close was refused even though the live viewer had moved off the target: $OUT"
if pane_exists "$PANE_FIVE_A"; then
  fail "the close reported success but left the target pane behind"
fi
[ "$(focused_tab)" = "$TAB_FIVE_B" ] \
  || fail "the close did not preserve the viewer's fresh non-target focus (focus is $(focused_tab), expected $TAB_FIVE_B)"
pass "attached viewer: a close preserves the fresh non-target focus the viewer moved to"

# --- scenario 7: the projection's seeded-tab prune inherits the refusal ----

FIXTURE=$(new_workspace viewer-seeded) || fail "could not create the scenario 7 workspace"
IFS=$'\t' read -r WS_SEVEN TAB_SEVEN_SEEDED PANE_SEVEN_SEEDED <<<"$FIXTURE"
FIXTURE=$(new_tab "$WS_SEVEN" fm-viewer-seeded-task) || fail "could not create the scenario 7 task tab"
IFS=$'\t' read -r _ PANE_SEVEN_TASK <<<"$FIXTURE"
lab tab list --workspace "$WS_SEVEN" \
  | jq -e --arg tab "$TAB_SEVEN_SEEDED" '.result.tabs[] | select(.tab_id == $tab) | .label == "1"' >/dev/null \
  || fail "the seeded tab is not the label-1 default tab the prune identifies"
lab tab focus "$TAB_SEVEN_SEEDED" >/dev/null || fail "could not focus the seeded tab"
[ "$(focused_tab)" = "$TAB_SEVEN_SEEDED" ] || fail "scenario 7 did not start focused on the seeded tab"

OUT=$(drive fm_backend_herdr_workspace_prune_seeded_default_tab \
  "$LAB_SESSION" "$WS_SEVEN" "$TAB_SEVEN_SEEDED" focus-preserving)
STATUS=$?
[ "$STATUS" -ne 0 ] || fail "the seeded prune did not refuse the tab a live viewer was watching: $OUT"
assert_contains "$OUT" "target is the captain's active tab" \
  "the seeded prune refusal did not come from the live-viewer guard: $OUT"
pane_exists "$PANE_SEVEN_SEEDED" \
  || fail "the seeded prune closed the tab the live viewer was watching"
pane_exists "$PANE_SEVEN_TASK" || fail "the seeded prune disturbed the task pane"
pass "attached viewer: the projection seeded-tab prune refuses while a live client watches it"

# --- detaching restores the no-client contract the detached tests rely on ---

"$LAB_HELPER" viewer stop "$LAB_SESSION" >/dev/null \
  || fail "could not detach the lab viewer"
REASON=$(foreground_reason) || fail "could not probe the session's foreground client"
[ "$REASON" = no_foreground_client ] \
  || fail "the lab still reported a foreground client after the viewer stopped (reason=$REASON)"
OUT=$(drive fm_backend_herdr_projection_close_pane_focus_preserving "$LAB_SESSION" "$PANE_THREE_A")
STATUS=$?
[ "$STATUS" -eq 0 ] || fail "the same close was still refused after the viewer detached: $OUT"
if pane_exists "$PANE_THREE_A"; then
  fail "the detached close reported success but left the pane behind"
fi
pass "attached viewer: detaching releases the refusal, so the guard tracks the client and not the pointer"
