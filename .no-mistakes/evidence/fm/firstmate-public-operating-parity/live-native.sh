#!/usr/bin/env bash
set -euo pipefail
. "$PWD/tests/fixtures.sh"
TMP_ROOT=$(fm_test_tmproot fm-lab-native-evidence)
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
COPY_ROOT="$TMP_ROOT/copies"
"$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR"
LAB_TMUX_DIR=$("$ROOT/bin/fm-lab-home.sh" tmux-dir "$HOME_DIR")
REAL_TMUX=$(command -v tmux)
TMUX_SOCKET=fm-lab
cleanup() {
  TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  "$ROOT/bin/fm-lab-home.sh" teardown "$HOME_DIR"
  fm_test_cleanup
}
trap cleanup EXIT
fm_git_init_commit "$PROJ"
printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
mkdir "$TMP_ROOT/socket-routing"
printf '#!/usr/bin/env bash\nexport TMUX_TMPDIR=%q\nexec %q -L %q "$@"\n' "$LAB_TMUX_DIR" "$REAL_TMUX" "$TMUX_SOCKET" > "$TMP_ROOT/socket-routing/tmux"
chmod +x "$TMP_ROOT/socket-routing/tmux"
export PATH="$TMP_ROOT/socket-routing:$PATH"
tmux -f /dev/null new-session -d -s firstmate -n main -c "$PROJ" /bin/sh
tmux set-option -g default-command '/bin/bash --noprofile --norc'
id="native-evidence-$$"
FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
fm_test_spawn_brief "$HOME_DIR" "$id"
marker="$TMP_ROOT/worker-cwd"
printf -v raw 'bash -c '\''pwd -P >> "$1"; sleep 60'\'' _ %q' "$marker"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT"
. "$ROOT/bin/fm-git-worktree-lib.sh"
base=$(git -C "$PROJ" rev-parse HEAD)
echo 'ACTION: reserve a copy before launch, then advance the accepted source'
fm_git_worktree_allocate "$HOME_DIR/state" "$id" "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$base" refs/heads/main
git -C "$PROJ" -c user.name=Tests -c user.email=tests@example.invalid commit --allow-empty -m 'source advances before launch'
echo 'ACTION: try to adopt that reservation under a foreign home (must refuse)'
mkdir "$TMP_ROOT/foreign-home"
if fm_git_worktree_allocate "$HOME_DIR/state" "$id" "$TMP_ROOT/foreign-home" "$PROJ" "$COPY_ROOT" "$base" refs/heads/main; then exit 1; fi
echo 'ACTION: spawn a shell marker worker through the real native allocator and private tmux'
FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$raw" --mode local-only --yolo off --backend tmux
WT="$COPY_ROOT/$id/worktree"
for _ in $(seq 1 30); do [ ! -s "$marker" ] || break; sleep 0.1; done
[ "$(cat "$marker")" = "$WT" ]
[ "$(git -C "$WT" rev-parse HEAD)" = "$base" ]
echo 'OBSERVED: launch resumed the exact reserved base after source advancement'
python3 "$ROOT/bin/fm-usage-auto.py" status
echo 'OBSERVED worker working directory:'
cat "$marker"
git -C "$PROJ" worktree list --porcelain
echo 'ACTION: attempt cleanup while worker is busy (must refuse)'
if FM_TEARDOWN_GUARD_DONE=1 bash "$ROOT/bin/fm-teardown.sh" "$id"; then exit 1; fi
[ -d "$WT" ] && [ -f "$HOME_DIR/state/$id.meta" ]
echo 'OBSERVED: busy copy and task record preserved'
tmux send-keys -t "firstmate:fm-$id" C-c
for _ in $(seq 1 30); do
  state=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "firstmate:fm-$id")
  [ "$state" != dead ] || break
  sleep 0.1
done
[ "$state" = dead ]
echo 'ACTION: try cleanup with untracked work present (must refuse and preserve bytes)'
printf 'preserve this work\n' > "$WT/local-work"
if FM_TEARDOWN_GUARD_DONE=1 bash "$ROOT/bin/fm-teardown.sh" "$id"; then exit 1; fi
[ "$(cat "$WT/local-work")" = 'preserve this work' ]
echo 'OBSERVED: untracked work remains unchanged'
rm "$WT/local-work"
echo 'ACTION: clean up the stopped, unchanged worker'
FM_TEARDOWN_GUARD_DONE=1 bash "$ROOT/bin/fm-teardown.sh" "$id"
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$id.meta" ] && [ ! -e "$HOME_DIR/state/$id.git-worktree" ]
echo 'OBSERVED: copy, metadata, and reservation retired; primary project remains'
git -C "$PROJ" worktree list --porcelain
