#!/usr/bin/env bash
# Behavior tests for the retired per-project worker limit: a home that still
# carries config/project-capacity keeps dispatching, because workers are no
# longer counted or capped (bin/fm-resource-lock.sh serializes heavy commands
# instead), and bin/fm-spawn.sh only says the file is no longer read.
#
# Every case drives the real bin/fm-spawn.sh against a real project clone with
# an origin, fake tmux and treehouse binaries, and a real markdown backlog when
# tasks-axi is installed. A spawn is judged by the record it published and by
# the declaration bytes it left alone, never by wording alone.
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

unset TASKS_AXI_BACKEND || :

SPAWN="$ROOT/bin/fm-spawn.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-capacity)
HAVE_TASKS_AXI=0
command -v tasks-axi >/dev/null 2>&1 && HAVE_TASKS_AXI=1

# --- fixture ----------------------------------------------------------------

write_brief() {  # <home> <id>
  mkdir -p "$1/data/$2"
  cat > "$1/data/$2/brief.md" <<EOF
# Task
## Captain's intent
Run the project's heavy suite for $2.

## Firstmate spec
Exercise project capacity admission.

# Definition of done
Delivery contract: mode=no-mistakes
EOF
}

# A Firstmate home with its own backlog (when tasks-axi is installed) and a
# brief for every named task.
make_home() {  # <home> [task-id...]
  local home=$1 id
  shift
  mkdir -p "$home/state" "$home/config" "$home/data" "$home/projects"
  touch "$home/state/.last-watcher-beat"
  printf '%s\n' codex > "$home/config/crew-harness"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    printf '%s\n' '# Backlog' '' '## In flight' '' '## Queued' '' '## Done' \
      > "$home/data/backlog.md"
    cat > "$home/.tasks.toml" <<'EOF'
backend = "markdown"

[markdown]
path = "data/backlog.md"
EOF
  fi
  for id in "$@"; do
    write_brief "$home" "$id"
    add_item "$home" "$id"
  done
}

# A case: one home, a project clone with an origin, and fake tmux/treehouse.
make_case() {  # <name> [task-id...]
  local name=$1 case_dir fakebin
  shift
  case_dir="$TMP_ROOT/$name"
  mkdir -p "$case_dir"
  fakebin=$(fm_fakebin "$case_dir")
  : > "$case_dir/calls.log"
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_FAKE_CALL_LOG"
case "$*" in
  *"#{pane_current_path}"*)
    printf '%s\n' "${FM_FAKE_PANE_PATH:-}"
    exit 0
    ;;
esac
case "${1:-}" in display-message) printf 'firstmate\n' ;; esac
exit 0
SH
  cat > "$fakebin/treehouse" <<'SH'
#!/usr/bin/env bash
printf 'treehouse %s\n' "$*" >> "$FM_FAKE_CALL_LOG"
exit 0
SH
  chmod +x "$fakebin/tmux" "$fakebin/treehouse"
  fm_fake_exit0 "$fakebin" gh gh-axi no-mistakes
  fm_git_init_commit "$case_dir/project"
  fm_git_add_origin "$case_dir/project" "$case_dir/project.origin.git"
  make_home "$case_dir/home" "$@"
  printf '%s\n' "$case_dir"
}

add_item() {  # <home> <id>
  [ "$HAVE_TASKS_AXI" = 1 ] || return 0
  tasks-axi add "$2" "item for $2" --kind ship --file "$1/data/backlog.md" >/dev/null
}

row_state() {  # <home> <id>
  tasks-axi show "$2" --file "$1/data/backlog.md" 2>/dev/null |
    sed -n 's/^  state: *//p' | head -1
}

declare_capacity() {  # <home> <line>...
  local home=$1
  shift
  printf '%s\n' "$@" > "$home/config/project-capacity"
}

# A live worker already on a project: the record shape bin/fm-spawn.sh
# publishes, with its backlog item In flight so cleanup can close it.
write_live() {  # <home> <id> <project-dir> [extra-line...]
  local home=$1 id=$2 project=$3
  shift 3
  fm_write_meta "$home/state/$id.meta" \
    "window=firstmate:fm-$id" \
    "endpoint_task_id=$id" \
    "worktree=$home/absent-worktree-$id" \
    "project=$project" \
    "harness=codex" \
    "kind=ship" \
    "mode=no-mistakes" \
    "yolo=off" \
    "spawn_gen=s-$id" \
    "$@"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    add_item "$home" "$id"
    tasks-axi start "$id" --file "$home/data/backlog.md" >/dev/null
  fi
}

# One isolated worktree per spawn, so every admitted launch has its own copy.
new_worktree() {  # <case-dir> <name>
  git -C "$1/project" worktree add --quiet -b "wt-$2" "$1/wt-$2"
  printf '%s\n' "$1/wt-$2"
}

run_spawn() {  # <case-dir> <home> <pane-path> <args...>
  local case_dir=$1 home=$2 pane=$3
  shift 3
  FM_ROOT_OVERRIDE='' FM_HOME="$home" \
    FM_STATE_OVERRIDE='' FM_DATA_OVERRIDE='' FM_PROJECTS_OVERRIDE='' FM_CONFIG_OVERRIDE='' \
    FM_SPAWN_NO_GUARD=1 TMUX="fake,1,0" FM_BACKEND=tmux \
    FM_FAKE_PANE_PATH="$pane" FM_FAKE_CALL_LOG="$case_dir/calls.log" \
    PATH="$case_dir/fakebin:$PATH" \
    "$SPAWN" "$@" 2>&1
}

spawn_ship() {  # <case-dir> <id> [pane-path]
  local case_dir=$1 id=$2 pane=${3:-}
  [ -n "$pane" ] || pane=$(new_worktree "$case_dir" "$id")
  run_spawn "$case_dir" "$case_dir/home" "$pane" "$id" "$case_dir/project" --mode no-mistakes --yolo off
}

# --- cases ------------------------------------------------------------------

# The shape the limit used to defer: the declaration admits one worker and two
# already work on the project. The spawn now launches anyway.
test_retired_declaration_no_longer_caps_dispatch() {
  local case_dir home out rc=0 before
  case_dir=$(make_case retired task-c)
  home="$case_dir/home"
  declare_capacity "$home" "# heavy suite serves one worker" "project 1"
  before=$(cat "$home/config/project-capacity")
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a home with the retired declaration refused a spawn: $out"
  assert_contains "$out" "spawned task-c" "a home with the retired declaration did not launch the worker"
  assert_not_contains "$out" "deferred:" "the retired declaration still deferred a spawn"
  assert_present "$home/state/task-c.meta" "the spawn published no record"
  assert_contains "$out" "notice: $home/config/project-capacity is no longer read" \
    "the spawn did not say the retired declaration is ignored"
  assert_contains "$out" "config/resource-locks" "the notice did not name the replacement"
  assert_equals "$before" "$(cat "$home/config/project-capacity")" "the spawn changed the captain's retired declaration"
  if [ "$HAVE_TASKS_AXI" = 1 ]; then
    [ "$(row_state "$home" task-c)" = in_flight ] || fail "the spawn did not move its item In flight"
  fi
  pass "a retired declaration no longer caps dispatch, is reported in one notice, and is left untouched"
}

# The old reader refused every spawn on a malformed or unreadable declaration.
# Nothing reads it now, so its contents cannot stop a launch.
test_unreadable_retired_declaration_does_not_refuse() {
  local case_dir home out rc=0
  case_dir=$(make_case unreadable task-c task-d)
  home="$case_dir/home"
  declare_capacity "$home" "project two" "project 1" "project 1"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a malformed retired declaration refused a spawn: $out"
  assert_present "$home/state/task-c.meta" "a malformed retired declaration stopped the launch"
  rm "$home/config/project-capacity"
  mkdir "$home/config/project-capacity"
  rc=0
  out=$(spawn_ship "$case_dir" task-d) || rc=$?
  expect_code 0 "$rc" "a retired declaration that is not a file refused a spawn: $out"
  assert_present "$home/state/task-d.meta" "a retired declaration that is not a file stopped the launch"
  pass "a malformed or unreadable retired declaration never refuses a spawn"
}

test_home_without_the_retired_declaration_gets_no_notice() {
  local case_dir home out rc=0
  case_dir=$(make_case absent task-c)
  home="$case_dir/home"
  write_live "$home" live-a "$case_dir/project"
  write_live "$home" live-b "$case_dir/project"
  out=$(spawn_ship "$case_dir" task-c) || rc=$?
  expect_code 0 "$rc" "a busy project refused a spawn: $out"
  assert_contains "$out" "spawned task-c" "a busy project did not launch the worker"
  assert_not_contains "$out" "notice:" "a home without the retired declaration was told about it"
  pass "a home without the retired declaration dispatches uncapped with no notice"
}

test_retired_declaration_no_longer_caps_dispatch
test_unreadable_retired_declaration_does_not_refuse
test_home_without_the_retired_declaration_gets_no_notice
