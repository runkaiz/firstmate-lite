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
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$alternate"
fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$alternate" "refs/heads/$MAIN" \
  || fail 'fast-forward source advance wedged an unpublished reservation'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail 'fast-forward recovery moved the reserved HEAD'
[ "$(fm_git_worktree_field "$HOME_DIR/state/resumed.git-worktree" base)" = "$BASE" ] || fail 'recovery rewrote the reserved base'
[ ! -e "$HOME_DIR/state/resumed.meta" ] || fail 'library recovery published task metadata'
rewritten=$(printf 'unrelated history\n' | git -C "$PROJ" -c user.name='Firstmate Tests' \
  -c user.email=tests@example.invalid commit-tree "$BASE^{tree}")
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$rewritten"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$rewritten" "refs/heads/$MAIN"; then
  fail 'rewritten source history adopted reservation'
fi
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$BASE"
git -C "$PROJ" branch alternate-source "$BASE"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$BASE" refs/heads/alternate-source; then
  fail 'different source ref adopted reservation'
fi
mkdir "$CASE/other-copies"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$CASE/other-copies" "$BASE" "refs/heads/$MAIN"; then
  fail 'changed root adopted reservation'
fi
fm_git_init_commit "$CASE/other-project"
other_base=$(git -C "$CASE/other-project" rev-parse HEAD)
other_main=$(git -C "$CASE/other-project" symbolic-ref --short HEAD)
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$CASE/other-project" "$COPY_ROOT" "$other_base" "refs/heads/$other_main"; then
  fail 'foreign project adopted reservation'
fi
printf 'worktree=%s\n' "$WT" > "$HOME_DIR/state/resumed.meta"
if allocate resumed; then fail 'published reservation was reused by a fresh allocation'; fi
rm "$HOME_DIR/state/resumed.meta"
mkdir "$CASE/foreign-home"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$CASE/foreign-home" "$PROJ" "$COPY_ROOT" "$BASE" "refs/heads/$MAIN"; then
  fail 'foreign home adopted reservation'
fi
remove_copy resumed || fail 'clean accepted copy did not remove'
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/resumed.git-worktree" ] || fail 'cleanup retained live reservation'
pass 'native reservation resumes one copy, rejects foreign ownership and removes clean accepted copy'

for stage in reservation container empty partial; do
  make_case "interrupt-$stage"
  mkdir() {
    if [ "$stage" = reservation ] && [ "${*: -1}" = "$COPY_ROOT/interrupted" ]; then return 1; fi
    command mkdir "$@"
  }
  git() {
    if [ "${3:-} ${4:-}" = 'worktree add' ]; then
      case "$stage" in
        container) return 1 ;;
        empty) command mkdir -m 700 "$6"; return 1 ;;
        partial) command git -C "$2" worktree add --detach --no-checkout "$6" "$7"; return 1 ;;
      esac
    fi
    command git "$@"
  }
  if allocate interrupted; then fail "fault $stage did not interrupt creation"; fi
  unset -f mkdir git
  [ -f "$HOME_DIR/state/interrupted.git-worktree" ] || fail "$stage lost reservation"
  [ ! -e "$HOME_DIR/state/interrupted.meta" ] || fail "$stage published metadata"
  if [ "$stage" = reservation ]; then
    [ ! -e "$COPY_ROOT/interrupted" ] || fail 'reservation was published after task directory creation'
  fi
  if [ "$stage" = partial ]; then
    git -C "$COPY_ROOT/interrupted/worktree" status --porcelain > "$CASE/before"
    if allocate interrupted; then fail 'partial checkout was treated as clean'; fi
    git -C "$COPY_ROOT/interrupted/worktree" status --porcelain > "$CASE/after"
    cmp "$CASE/before" "$CASE/after" || fail 'partial checkout refusal changed work'
  else
    allocate interrupted || fail "$stage reservation could not resume"
    [ "$(git -C "$FM_GIT_WORKTREE_PATH" rev-parse HEAD)" = "$BASE" ] || fail "$stage recovery changed base"
    remove_copy interrupted || fail "$stage resumed copy could not be removed"
  fi
  pass "native $stage interruption preserves ownership and resumes only clean creation"
done

make_case branch
allocate branch || fail 'branch fixture allocation failed'
git -C "$FM_GIT_WORKTREE_PATH" switch -qc user-branch
if allocate branch; then fail 'recovery adopted a changed branch at the same base'; fi
[ "$(git -C "$FM_GIT_WORKTREE_PATH" symbolic-ref --short HEAD)" = user-branch ] || fail 'branch refusal changed user branch'
pass 'native recovery preserves a user branch even at the recorded base'

make_case live
allocate live || fail 'live fixture allocation failed'
WT=$FM_GIT_WORKTREE_PATH
bash -c 'cd "$1" && printf ready > "$2" && exec sleep 60' _ "$WT" "$CASE/ready" &
owner=$!
for _ in $(seq 1 100); do [ ! -f "$CASE/ready" ] || break; sleep 0.01; done
if [ ! -f "$CASE/ready" ]; then kill "$owner"; wait "$owner" || true; fail 'live owner did not start'; fi
if allocate live; then kill "$owner"; wait "$owner" || true; fail 'live process owner was ignored'; fi
kill "$owner"
wait "$owner" || true
fakebin=$(fm_fakebin "$CASE/fake")
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/lsof"
chmod +x "$fakebin/lsof"
if PATH="$fakebin:$PATH" allocate live; then fail 'unverifiable process ownership was accepted'; fi
allocate live || fail 'clean reservation could not resume after owner exited'
pass 'native recovery refuses live and unverified owners'

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
if allocate content; then fail 'untracked copy was resumed'; fi
if remove_copy content; then fail 'untracked content was discarded'; fi
[ "$(cat "$WT/untracked")" = untracked ] || fail 'untracked bytes lost'
rm "$WT/untracked"
printf 'ignored\n' >> "$PROJ/.git/info/exclude"
printf 'private\n' > "$WT/ignored"
if allocate content; then fail 'ignored content was resumed'; fi
if remove_copy content; then fail 'ignored untracked content was discarded'; fi
[ "$(cat "$WT/ignored")" = private ] || fail 'ignored bytes lost'
rm "$WT/ignored"
printf 'tracked edit\n' >> "$WT/README.md"
if allocate content; then fail 'tracked dirt was resumed'; fi
if remove_copy content; then fail 'tracked dirt was discarded'; fi
git -C "$WT" add README.md
git -C "$WT" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit -qm unlanded
git -C "$WT" branch retained-unlanded
if allocate content; then fail 'changed HEAD was resumed'; fi
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
  if [ "$kind" = remote ]; then
    git -C "$PROJ" fetch -q origin
    fm_git_worktree_allocate "$HOME_DIR/state" "$id" "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$remote" "refs/remotes/origin/$MAIN" \
      || fail 'remote reservation fixture failed'
    advanced=$(printf 'remote advance\n' | git -C "$PROJ" -c user.name='Firstmate Tests' \
      -c user.email=tests@example.invalid commit-tree "$remote^{tree}" -p "$remote")
    git -C "$PROJ" update-ref refs/heads/remote-fixture "$advanced"
    git -C "$CASE/origin.git" fetch -q "$PROJ" "refs/heads/remote-fixture:refs/heads/$MAIN"
  fi
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$id" "$PROJ" 'sh -c true' "${args[@]}" 2>&1)
  rc=$?
  expect_code 0 "$rc" "native $kind spawn failed: $out"
  expected=$local_head
  [ "$kind" != remote ] || expected=$remote
  [ "$(git -C "$WT" rev-parse HEAD)" = "$expected" ] || fail "$kind chose the wrong source"
  assert_contains "$out" "base=$expected" 'spawn reported a different base than the actual reserved copy'
  assert_grep 'allocator=git' "$HOME_DIR/state/$id.meta" 'native identity was not recorded'
  if out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$id" "$PROJ" 'sh -c true' "${args[@]}" 2>&1); then
    fail 'duplicate task spawn started another worker'
  fi
  [ "$(git -C "$PROJ" worktree list --porcelain | grep -c '^worktree ')" = 2 ] || fail 'duplicate spawn allocated another copy'
  pass "native $kind selects exact accepted source on divergence and refuses duplicate spawn"
done

fm_live_gate default-on FM_NATIVE_TMUX_LIVE_E2E tmux pgrep lsof

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
