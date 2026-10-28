#!/usr/bin/env bash
# Native allocation/reservation/source and conservative removal regressions.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-git-worktree-lib.sh disable=SC1091
. "$ROOT/bin/fm-git-worktree-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-worktree)

make_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  COPY_ROOT="$CASE/copies"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_init_commit "$PROJ"
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  MAIN=$(git -C "$PROJ" symbolic-ref --short HEAD)
  printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
  printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
  printf -- '- project [local-only]\n' > "$HOME_DIR/data/projects.md"
}

allocate() {
  fm_git_worktree_allocate "$HOME_DIR/state" "$1" "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$BASE" "refs/heads/$MAIN"
}
remove_copy() {
  fm_git_worktree_remove "$HOME_DIR/state" "$1" "$HOME_DIR" "$PROJ" "$COPY_ROOT/$1/worktree"
}

make_case resume
allocate resumed || fail 'initial native allocation failed'
WT=$FM_GIT_WORKTREE_PATH
git -C "$PROJ" worktree list --porcelain > "$CASE/before"
# Repeating after a caller interruption reuses the reservation/copy, not add.
allocate resumed || fail 'interrupted allocation did not resume'
git -C "$PROJ" worktree list --porcelain > "$CASE/after"
cmp "$CASE/before" "$CASE/after" || fail 'recovery created another copy'
[ "$WT" = "$FM_GIT_WORKTREE_PATH" ] || fail 'recovery changed identity'
printf 'worktree=%s\n' "$WT" > "$CASE/inconsistent.meta"
if fm_git_worktree_meta_allocator "$CASE/inconsistent.meta" "$HOME_DIR/state/resumed.git-worktree"; then
  fail 'missing allocator could route native copy through pooled cleanup'
fi
printf 'allocator=git\nallocator=treehouse\n' > "$CASE/inconsistent.meta"
if fm_git_worktree_meta_allocator "$CASE/inconsistent.meta" "$HOME_DIR/state/resumed.git-worktree"; then
  fail 'ambiguous allocator metadata was accepted'
fi
alternate=$(printf 'different source\n' | git -C "$PROJ" -c user.name='Firstmate Tests' \
  -c user.email=tests@example.invalid commit-tree "$BASE^{tree}" -p "$BASE")
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$alternate" "refs/heads/$MAIN"; then
  fail 'recovery silently rebased a reserved source'
fi
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail 'changed-source refusal moved HEAD'
mkdir "$CASE/foreign-home"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$CASE/foreign-home" "$PROJ" "$COPY_ROOT" "$BASE" "refs/heads/$MAIN"; then
  fail 'foreign home adopted reservation'
fi
remove_copy resumed || fail 'clean accepted copy did not remove'
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/resumed.git-worktree" ] || fail 'cleanup retained live reservation'
pass 'native reservation resumes one copy, rejects foreign ownership and removes clean accepted copy'

make_case collisions
mkdir -p "$COPY_ROOT/collision"
printf 'preserve\n' > "$COPY_ROOT/collision/sentinel"
if allocate collision; then fail 'existing unrelated task path was overwritten'; fi
[ "$(cat "$COPY_ROOT/collision/sentinel")" = preserve ] || fail 'collision lost bytes'
if fm_git_worktree_allocate "$HOME_DIR/state" nested "$HOME_DIR" "$PROJ" "$PROJ/unsafe" "$BASE" "refs/heads/$MAIN"; then
  fail 'allocator accepted a root inside primary'
fi
[ ! -e "$PROJ/unsafe" ] || fail 'unsafe root preflight wrote inside primary'
pass 'native allocation refuses existing paths and primary roots before writing them'

make_case content
allocate content || fail 'content fixture allocation failed'
WT=$FM_GIT_WORKTREE_PATH
printf 'untracked\n' > "$WT/untracked"
if remove_copy content; then fail 'untracked content was discarded'; fi
[ "$(cat "$WT/untracked")" = untracked ] || fail 'untracked bytes lost'
rm "$WT/untracked"
printf 'ignored\n' >> "$PROJ/.git/info/exclude"
printf 'private\n' > "$WT/ignored"
if remove_copy content; then fail 'ignored untracked content was discarded'; fi
[ "$(cat "$WT/ignored")" = private ] || fail 'ignored bytes lost'
rm "$WT/ignored"
printf 'tracked edit\n' >> "$WT/README.md"
if remove_copy content; then fail 'tracked dirt was discarded'; fi
git -C "$WT" add README.md
git -C "$WT" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit -qm unlanded
git -C "$WT" branch retained-unlanded
if remove_copy content; then fail 'unlanded committed work was discarded'; fi
[ -d "$WT" ] && [ -f "$HOME_DIR/state/content.git-worktree" ] || fail 'refusal lost copy/record'
pass 'native cleanup preserves untracked, ignored, dirty and unlanded content'

for kind in ship scout remote; do
  make_case "source-$kind"
  # Local and origin share a base but then diverge, matching the recurrence.
  git clone -q --bare "$PROJ" "$CASE/origin.git"
  git -C "$PROJ" remote add origin "file://$CASE/origin.git"
  remote=$(printf 'remote divergence\n' | git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit-tree "$BASE^{tree}" -p "$BASE")
  git -C "$PROJ" update-ref refs/heads/remote-fixture "$remote"
  git -C "$CASE/origin.git" fetch -q "$PROJ" "refs/heads/remote-fixture:refs/heads/$MAIN"
  printf 'accepted locally\n' > "$PROJ/local-only"
  git -C "$PROJ" add local-only
  git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit -qm local-accepted
  local_head=$(git -C "$PROJ" rev-parse HEAD)
  id="native-$kind-$$"
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
  fm_test_spawn_brief "$HOME_DIR" "$id"
  fakebin=$(make_spawn_fakebin "$CASE/fake")
  WT="$COPY_ROOT/$id/worktree"
  args=(--mode local-only --yolo off)
  [ "$kind" != scout ] || args=(--scout)
  [ "$kind" != remote ] || args=(--mode no-mistakes --yolo off)
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$id" "$PROJ" 'sh -c true' "${args[@]}" 2>&1)
  rc=$?
  expect_code 0 "$rc" "native $kind spawn failed: $out"
  expected=$local_head
  [ "$kind" != remote ] || expected=$remote
  [ "$(git -C "$WT" rev-parse HEAD)" = "$expected" ] || fail "$kind chose the wrong source"
  assert_grep 'allocator=git' "$HOME_DIR/state/$id.meta" 'native identity was not recorded'
  if out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$id" "$PROJ" 'sh -c true' "${args[@]}" 2>&1); then
    fail 'duplicate task spawn started another worker'
  fi
  [ "$(git -C "$PROJ" worktree list --porcelain | grep -c '^worktree ')" = 2 ] || fail 'duplicate spawn allocated another copy'
  pass "native $kind selects exact accepted source on divergence and refuses duplicate spawn"
done

if command -v tmux >/dev/null 2>&1 && command -v pgrep >/dev/null 2>&1 && command -v lsof >/dev/null 2>&1; then
  LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
  HOME_DIR="$TMP_ROOT/tmux-home"
  PROJ="$TMP_ROOT/tmux-project"
  COPY_ROOT="$TMP_ROOT/tmux-copies"
  "$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null || fail 'could not mark tmux lab home'
  LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$HOME_DIR") || fail 'could not create private tmux socket dir'
  REAL_TMUX=$(command -v tmux)
  TMUX_SOCKET="native-$$"
  cleanup_native_tmux() {
    local status=$?
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
    "$LAB_HOME_HELPER" teardown "$HOME_DIR" || status=1
    fm_test_cleanup
    exit "$status"
  }
  trap cleanup_native_tmux EXIT
  fm_git_init_commit "$PROJ"
  printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
  printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  tmux_shim=$(fm_fakebin "$TMP_ROOT/native-tmux-shim")
  {
    printf '#!/usr/bin/env bash\n'
    printf 'export TMUX_TMPDIR=%q\nexec %q -L %q "$@"\n' "$LAB_TMUX_DIR" "$REAL_TMUX" "$TMUX_SOCKET"
  } > "$tmux_shim/tmux"
  chmod +x "$tmux_shim/tmux"
  TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$TMUX_SOCKET" -f /dev/null \
    new-session -d -s firstmate -n main -c "$PROJ" /bin/sh || fail 'could not start private tmux lab'
  TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$TMUX_SOCKET" set-option -g default-command '/bin/bash --noprofile --norc'
  id="native-tmux-$$"
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
  fm_test_spawn_brief "$HOME_DIR" "$id"
  marker="$TMP_ROOT/tmux-worker"
  # shellcheck disable=SC2016
  printf -v raw 'bash -c '\''pwd -P >> "$1"; sleep 60'\'' _ %q' "$marker"
  out=$(env PATH="$tmux_shim:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
    bash "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$raw" --mode local-only --yolo off --backend tmux 2>&1)
  expect_code 0 "$?" "real native tmux launch failed: $out"
  WT="$COPY_ROOT/$id/worktree"
  for _ in $(seq 1 30); do [ ! -s "$marker" ] || break; sleep 0.1; done
  [ "$(cat "$marker")" = "$WT" ] || fail 'native tmux worker did not execute once in isolated copy'
  if out=$(env PATH="$tmux_shim:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
    bash "$ROOT/bin/fm-teardown.sh" "$id" 2>&1); then fail 'native tmux teardown killed a busy owner'; fi
  env PATH="$tmux_shim:$PATH" tmux send-keys -t "firstmate:fm-$id" C-c
  for _ in $(seq 1 30); do
    # Positional parameters are supplied to the nested Bash classifier.
    # shellcheck disable=SC2016
    state=$(env PATH="$tmux_shim:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "firstmate:fm-$id")
    [ "$state" != dead ] || break
    sleep 0.1
  done
  [ "$state" = dead ] || fail 'native tmux marker did not return to idle shell'
  out=$(env PATH="$tmux_shim:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
    bash "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
  expect_code 0 "$?" "real clean native tmux teardown failed: $out"
  [ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$id.meta" ] && [ ! -e "$HOME_DIR/state/$id.git-worktree" ] \
    || fail 'native tmux cleanup left copy/records'
  pass 'real native tmux worker owns one isolated copy; busy refusal and clean teardown preserve lifecycle guards'
else
  printf 'skip: native tmux live case needs tmux, pgrep and lsof; portable native cases completed\n'
fi
