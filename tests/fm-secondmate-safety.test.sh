#!/usr/bin/env bash
# Ordinary home isolation, task-set contention, and retired-supervisor preservation.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-home-safety)
export FM_BACKEND=tmux
HOLDERS=()
cleanup_home_safety() {
  local pid
  for pid in "${HOLDERS[@]+"${HOLDERS[@]}"}"; do kill "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup_home_safety EXIT
make_fake_tmux() {
  local dir=$1
  mkdir -p "$dir/bin"
  : > "$dir/tmux.log"
  cat > "$dir/bin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_TMUX_LOG"
case "${1:-}" in list-windows) printf 'other-session:fm-missing\n' ;; esac
SH
  chmod +x "$dir/bin/tmux"
  printf '%s\n' "$dir/bin"
}
task_set_lock_path() {
  # shellcheck source=bin/fm-wake-lib.sh
  . "$ROOT/bin/fm-wake-lib.sh"
  fm_task_set_lock_path "$1"
}
seed_task_set_lock_home() {
  local home="$TMP_ROOT/$1-home"
  mkdir -p "$home/state" "$home/data" "$home/config" "$home/projects"
  fm_git_init_commit "$home/projects/alpha"
  printf '%s|%s\n' "$home" "$home"
}

test_fm_home_parameterization() {
  local brief home_one home_two out
  home_one="$TMP_ROOT/home one"
  home_two="$TMP_ROOT/home-two"
  mkdir -p "$home_one/data" "$home_one/state" "$home_two/data" "$home_two/state"
  printf '%s\n' '- app [local-only +yolo] - test app (added 2026-06-22)' > "$home_one/data/projects.md"

  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-project-mode.sh" app)
  [ "$out" = "local-only on" ] || fail "fm-project-mode did not read projects.md from FM_HOME"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-project-mode.sh" app 2>/dev/null)
  [ "$out" = "no-mistakes off" ] || fail "fm-project-mode did not isolate missing registry by home"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-a app --mode no-mistakes >/dev/null || fail "brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-a/brief.md"
  [ -f "$brief" ] || fail "brief was not written under FM_HOME/data"
  grep -F ">> '$home_one/state/task-a.status'" "$brief" >/dev/null || fail "brief did not shell-quote FM_HOME state path"

  FM_HOME="$home_one" "$ROOT/bin/fm-brief.sh" task-b app --scout >/dev/null || fail "scout brief scaffold failed under FM_HOME"
  brief="$home_one/data/task-b/brief.md"
  grep -F ">> '$home_one/state/task-b.status'" "$brief" >/dev/null || fail "scout brief did not shell-quote FM_HOME state path"

  # A pushed ship worktree, and a gh that supplies no forge head, so the PR
  # check stays offline and its named-head gate reads the worktree's HEAD.
  fm_git_init_commit "$home_one/wt"
  git -C "$home_one/wt" update-ref refs/remotes/origin/main "$(git -C "$home_one/wt" rev-parse HEAD)"
  mkdir -p "$home_one/fakebin"
  printf '#!/usr/bin/env bash\nexit 1\n' > "$home_one/fakebin/gh"
  chmod +x "$home_one/fakebin/gh"
  printf 'project=x\nworktree=%s\n' "$home_one/wt" > "$home_one/state/task-a.meta"
  PATH="$home_one/fakebin:$PATH" FM_HOME="$home_one" FM_GUARD_GRACE=999999 \
    "$ROOT/bin/fm-pr-check.sh" task-a https://github.com/example/repo/pull/1 >/dev/null 2>/dev/null \
    || fail "fm-pr-check failed under FM_HOME"
  [ -f "$home_one/state/task-a.check.sh" ] || fail "pr check was not written under FM_HOME/state"
  [ ! -e "$home_two/state/task-a.check.sh" ] || fail "pr check leaked into another home"
  pass "FM_HOME parameterizes data and state paths"
}

test_lock_status_is_per_home() {
  local home_one home_two out
  home_one="$TMP_ROOT/lock-one"
  home_two="$TMP_ROOT/lock-two"
  mkdir -p "$home_one/state" "$home_two/state"
  printf '999999\n' > "$home_one/state/.lock"
  out=$(FM_HOME="$home_one" "$ROOT/bin/fm-lock.sh" status)
  printf '%s\n' "$out" | grep -F 'lock: stale' >/dev/null || fail "home one lock status did not read its own lock"
  out=$(FM_HOME="$home_two" "$ROOT/bin/fm-lock.sh" status)
  [ "$out" = "lock: free" ] || fail "home two lock status was affected by home one"
  pass "fm-lock status is scoped per home"
}

test_fm_send_refuses_bare_window_without_home_meta() {
  # The happy path (a bare fm-<id> resolves the window recorded in THIS home's
  # meta and never a foreign same-named window) is asserted in the lifecycle e2e.
  # Here: with NO meta for the id, send must refuse rather than fall back to a
  # foreign same-named window that list-windows happens to return.
  local home fakebin log err
  home="$TMP_ROOT/send-home"
  mkdir -p "$home/state"
  touch "$home/state/.last-watcher-beat"
  fakebin=$(make_fake_tmux "$TMP_ROOT/send-fake")
  log="$TMP_ROOT/send-fake/tmux.log"
  err="$TMP_ROOT/send-fake/send.err"

  if PATH="$fakebin:$PATH" FM_HOME="$home" FM_FAKE_TMUX_WINDOW="other-session:fm-missing" FM_FAKE_TMUX_LOG="$log" FM_FAKE_TMUX_CAPTURE="$TMP_ROOT/send-fake/pane.txt" \
    "$ROOT/bin/fm-send.sh" fm-missing 'wrong home' >/dev/null 2>"$err"; then
    fail "fm-send sent to a bare firstmate window without home metadata"
  fi
  grep -F "no metadata for fm-missing in $home/state" "$err" >/dev/null \
    || fail "fm-send did not explain missing home metadata"
  grep -F 'send-keys -t other-session:fm-missing' "$log" >/dev/null \
    && fail "fm-send fell back to a foreign same-name window"
  pass "fm-send refuses a bare firstmate window with no metadata in this home"
}

hold_task_set_lock() {  # <state-dir> [role] -> echoes "<holder-pid> <lock-path>"
  local state=$1 role=${2:-} lock holder i=0
  lock=$(task_set_lock_path "$state") || return 1
  [ -n "$lock" ] || return 1
  # stdout/stderr are redirected so the long-lived holder does not inherit this
  # function's command-substitution pipe; leaving it open would block the caller
  # until the holder exited, by which point the lock would be stale and the
  # contention under test could not happen.
  (
    # shellcheck source=/dev/null
    . "$ROOT/bin/fm-wake-lib.sh"
    fm_lock_try_acquire "$lock" || exit 1
    [ -z "$role" ] || fm_lock_set_role "$lock" "$role" || exit 1
    sleep 30
  ) >/dev/null 2>&1 &
  # shellcheck disable=SC2031 # The background PID is captured immediately in this shell.
  holder=$!
  while [ ! -e "$lock" ] && [ "$i" -lt 100 ]; do
    sleep 0.1
    i=$((i + 1))
  done
  [ -e "$lock" ] || {
    kill "$holder" 2>/dev/null || true
    wait "$holder" 2>/dev/null || true
    return 1
  }
  if [ -n "$role" ]; then
    while [ "$(cat "$lock/role" 2>/dev/null || true)" != "$role" ] && [ "$i" -lt 100 ]; do
      sleep 0.1
      i=$((i + 1))
    done
    [ "$(cat "$lock/role" 2>/dev/null || true)" = "$role" ] || {
      kill "$holder" 2>/dev/null || true
      wait "$holder" 2>/dev/null || true
      return 1
    }
  fi
  printf '%s %s\n' "$holder" "$lock"
}

test_fresh_spawn_refuses_while_a_forced_teardown_owns_the_task_set() {
  local home subhome err rec held holder lock
  rec=$(seed_task_set_lock_home taskset-spawn)
  IFS='|' read -r home subhome <<EOF
$rec
EOF
  err="$TMP_ROOT/taskset-spawn.err"
  # Stand in for a forced teardown that already enumerated this home's task set.
  held=$(hold_task_set_lock "$subhome/state" forced-teardown) \
    || fail "could not stage a held task-set lock"
  holder=${held%% *}
  HOLDERS+=("$holder")
  lock=${held#* }
  if FM_HOME="$subhome" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" newtask "$subhome/projects/alpha" --scout >/dev/null 2>"$err"; then
    kill "$holder" 2>/dev/null || true
    fail "a fresh spawn published a task while a forced teardown owned the set"
  fi
  [ ! -e "$subhome/state/newtask.meta" ] \
    || fail "a refused spawn still published a durable record"
  [ -e "$lock" ] || fail "a refused spawn removed the teardown's task-set lock"
  grep -F "task set is locked by a forced teardown" "$err" >/dev/null \
    || fail "the spawn refusal did not name the task-set contention: $(cat "$err")"
  [ ! -e "$subhome/state/.spawn-newtask.lock" ] \
    || fail "a refused spawn left its own task lock behind"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "a fresh spawn refuses to publish while a forced teardown owns the task set"
}

test_fresh_spawn_names_another_spawn_as_task_set_holder() {
  local home subhome err rec held holder
  rec=$(seed_task_set_lock_home taskset-two-spawns)
  IFS='|' read -r home subhome <<EOF
$rec
EOF
  err="$TMP_ROOT/taskset-two-spawns.err"
  held=$(hold_task_set_lock "$subhome/state" task-spawn) \
    || fail "could not stage a fresh spawn holding the task-set lock"
  holder=${held%% *}
  HOLDERS+=("$holder")
  if FM_HOME="$subhome" FM_SPAWN_NO_GUARD=1 \
    "$ROOT/bin/fm-spawn.sh" newtask "$subhome/projects/alpha" --scout >/dev/null 2>"$err"; then
    kill "$holder" 2>/dev/null || true
    fail "a fresh spawn published while another spawn owned the task set"
  fi
  grep -F "task set is locked by another spawn" "$err" >/dev/null \
    || fail "the refusal did not name the other spawn: $(cat "$err")"
  [ ! -e "$subhome/state/newtask.meta" ] || fail "a refused spawn published a task"
  kill "$holder" 2>/dev/null || true
  wait "$holder" 2>/dev/null || true
  pass "a fresh spawn refusal identifies another spawn as the task-set holder"
}

test_retired_supervisor_records_are_preserved() {
  local home="$TMP_ROOT/legacy-home" main="$TMP_ROOT/operator" out rc entry
  mkdir -p "$home/state" "$home/data" "$home/config" "$main/state" "$main/data"
  printf 'retired\n' > "$home/.fm-secondmate-home"
  printf 'private sentinel\n' > "$home/data/sentinel"
  for entry in fm-session-start.sh fm-bootstrap.sh; do
    out=$(FM_HOME="$home" bash "$ROOT/bin/$entry" 2>&1); rc=$?
    [ "$rc" -ne 0 ] || fail "$entry revived a retired supervisor home"
    assert_contains "$out" 'no longer supported' "$entry did not explain retirement"
    assert_grep 'private sentinel' "$home/data/sentinel" "$entry changed private history"
  done
  printf 'kind=secondmate\nworktree=%s\nhome=%s\nwindow=firstmate:fm-retired\n' "$home" "$home" > "$main/state/retired.meta"
  cp "$main/state/retired.meta" "$TMP_ROOT/retired-before"
  for entry in fm-control.sh fm-teardown.sh; do
    if [ "$entry" = fm-control.sh ]; then
      out=$(FM_HOME="$main" bash "$ROOT/bin/$entry" retired exit 2>&1); rc=$?
    else
      out=$(FM_HOME="$main" bash "$ROOT/bin/$entry" retired 2>&1); rc=$?
    fi
    [ "$rc" -ne 0 ] || fail "$entry accepted a retired supervisor lifecycle action"
    assert_contains "$out" 'unsupported' "$entry did not explain preserved retirement"
    cmp -s "$main/state/retired.meta" "$TMP_ROOT/retired-before" || fail "$entry changed the retired record"
    assert_grep 'private sentinel' "$home/data/sentinel" "$entry removed the private home"
  done
  out=$(FM_HOME="$main" bash "$ROOT/bin/fm-spawn.sh" retired --secondmate 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "retired supervisor spawn was accepted"
  out=$(FM_HOME="$main" bash "$ROOT/bin/fm-brief.sh" retired --secondmate 2>&1); rc=$?
  [ "$rc" -ne 0 ] || fail "retired supervisor charter was accepted"
  pass "retired supervisor startup, creation and lifecycle refuse while private homes and metadata survive"
}

test_fm_home_parameterization
test_lock_status_is_per_home
test_fm_send_refuses_bare_window_without_home_meta
test_fresh_spawn_refuses_while_a_forced_teardown_owns_the_task_set
test_fresh_spawn_names_another_spawn_as_task_set_holder
test_retired_supervisor_records_are_preserved
