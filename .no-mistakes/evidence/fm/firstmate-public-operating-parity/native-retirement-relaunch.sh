#!/usr/bin/env bash
set -Eeuo pipefail
export LC_ALL=C FM_TEST_SKIP_ORPHAN_REAP=1
export TMPDIR="$PWD/.test-phase/tmp"
mkdir -p "$TMPDIR"
. "$PWD/tests/fixtures.sh"
EVIDENCE=/home/runkai/.no-mistakes/evidence/01M61Q39ZYPMGTHHT7DZ77ZHWN
TMP_ROOT=$(fm_test_tmproot fm-lab-native-retry)
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
COPY_ROOT="$TMP_ROOT/copies"
REAL_TMUX=$(command -v tmux)
REAL_RM=$(command -v rm)
LAB_TMUX_DIR=
id="native-retry-$$"
START=$SECONDS
snapshot() {
  local phase=$1 file
  mkdir -p "$EVIDENCE/native-retry-records/$phase"
  for file in "$HOME_DIR/state/$id".*; do
    [ -f "$file" ] || continue
    cp -p "$file" "$EVIDENCE/native-retry-records/$phase/"
  done
  git -C "$PROJ" worktree list --porcelain > "$EVIDENCE/native-retry-records/$phase/worktrees.txt"
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L fm-lab list-panes -a -F '#{session_name}:#{window_name} #{pane_id} pid=#{pane_pid} command=#{pane_current_command} cwd=#{pane_current_path}' || true
  fi
}
cleanup() {
  local rc=$?
  trap - EXIT
  if [ "$rc" != 0 ]; then
    echo "NO-GO exit=$rc elapsed=$((SECONDS-START))"
    snapshot failure || true
    cp -a "$TMP_ROOT" "$EVIDENCE/native-retry-failed-fixture" || true
  fi
  if [ -n "$LAB_TMUX_DIR" ]; then
    TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L fm-lab kill-server >/dev/null 2>&1 || true
    bash "$ROOT/bin/fm-lab-home.sh" teardown "$HOME_DIR"
  fi
  fm_test_cleanup
  echo "CLEANUP exit=$rc elapsed=$((SECONDS-START)) seconds"
  exit "$rc"
}
trap cleanup EXIT
bash "$ROOT/bin/fm-lab-home.sh" create "$HOME_DIR"
LAB_TMUX_DIR=$(bash "$ROOT/bin/fm-lab-home.sh" tmux-dir "$HOME_DIR")
fm_git_init_commit "$PROJ"
printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
mkdir "$TMP_ROOT/socket-routing" "$TMP_ROOT/fault"
printf '#!/usr/bin/env bash\nexport TMUX_TMPDIR=%q\nexec %q -L fm-lab "$@"\n' "$LAB_TMUX_DIR" "$REAL_TMUX" > "$TMP_ROOT/socket-routing/tmux"
chmod +x "$TMP_ROOT/socket-routing/tmux"
export PATH="$TMP_ROOT/socket-routing:$PATH"
tmux -f /dev/null new-session -d -s firstmate -n main -c "$PROJ" /bin/sh
tmux set-option -g default-command '/bin/bash --noprofile --norc'
FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
fm_test_spawn_brief "$HOME_DIR" "$id"
export FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT"
marker="$TMP_ROOT/worker-cwd"
printf -v raw 'bash -c '\''printf "pid=%%s cwd=%%s\\n" "$$" "$PWD" >> "$1"; sleep 2'\'' _ %q' "$marker"
run() {
  printf 'COMMAND'; printf ' %q' "$@"; printf '\n'
  local rc=0
  "$@" || rc=$?
  echo "COMMAND_EXIT=$rc"
  return "$rc"
}
wait_stopped() {
  local count=$1 state
  for _ in $(seq 1 80); do
    state=$(bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "firstmate:fm-$id")
    if [ -f "$marker" ] && [ "$(wc -l < "$marker")" = "$count" ] && [ "$state" = dead ]; then
      echo "OBSERVED marker_count=$count endpoint_state=$state"
      cat "$marker"
      return 0
    fi
    sleep 0.25
  done
  echo "NO-GO marker worker did not finish: state=$state"
  return 1
}
echo "START head=$(git rev-parse HEAD) pid=$$ private_socket=$LAB_TMUX_DIR/tmux-$(id -u)/fm-lab"
echo "EVIDENCE TYPE: real production CLI and tmux, non-model shell marker"
run env FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$raw" --mode local-only --yolo off --backend tmux
WT="$COPY_ROOT/$id/worktree"
wait_stopped 1
snapshot before-relaunch
cp "$HOME_DIR/state/$id.git-worktree" "$TMP_ROOT/reservation.before"
git -C "$PROJ" worktree list --porcelain > "$TMP_ROOT/inventory.before"
printf 'treehouse\n' > "$HOME_DIR/config/worktree-allocator"
echo 'ACTION: change only allocator default, relaunch the stopped marker through production spawn'
run env FM_SPAWN_NO_GUARD=1 bash "$ROOT/bin/fm-spawn.sh" "$id" --relaunch --harness "$raw"
wait_stopped 2
cmp "$TMP_ROOT/reservation.before" "$HOME_DIR/state/$id.git-worktree"
git -C "$PROJ" worktree list --porcelain > "$TMP_ROOT/inventory.after"
cmp "$TMP_ROOT/inventory.before" "$TMP_ROOT/inventory.after"
grep -Fx 'allocator=git' "$HOME_DIR/state/$id.meta"
grep -Fx "worktree=$WT" "$HOME_DIR/state/$id.meta"
[ "$(grep -Fc "cwd=$WT" "$marker")" = 2 ]
snapshot after-relaunch
echo 'PASS: recorded allocator, copy, reservation and inventory preserved'
cat > "$TMP_ROOT/fault/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_RETIRE_PATH:?}" ]; then
    echo "INJECTED reservation retirement failure pid=$$ parent=$PPID path=$arg" >&2
    ps -o pid,ppid,lstart,args -p "$$,$PPID" >&2
    exit 1
  fi
done
exec "${FM_TEST_REAL_RM:?}" "$@"
SH
chmod +x "$TMP_ROOT/fault/rm"
rc=0
run env PATH="$TMP_ROOT/fault:$PATH" FM_TEST_REAL_RM="$REAL_RM" FM_TEST_RETIRE_PATH="$HOME_DIR/state/$id.git-worktree" FM_TEARDOWN_GUARD_DONE=1 bash "$ROOT/bin/fm-teardown.sh" "$id" || rc=$?
[ "$rc" != 0 ]
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$id.meta" ]
[ -f "$HOME_DIR/state/$id.git-worktree" ] && [ -f "$HOME_DIR/state/$id.backlog-close" ]
cmp "$TMP_ROOT/reservation.before" "$HOME_DIR/state/$id.git-worktree"
snapshot interrupted-retirement
echo 'PASS: failure is nonzero, copy and metadata retired, exact reservation and replay marker retained'
run env FM_BOOTSTRAP_NETWORK=skip bash "$ROOT/bin/fm-bootstrap.sh"
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$id.meta" ]
[ ! -e "$HOME_DIR/state/$id.git-worktree" ] && [ ! -e "$HOME_DIR/state/$id.backlog-close" ]
[ -d "$PROJ/.git" ]
[ -z "$(git -C "$PROJ" status --porcelain)" ]
snapshot after-replay
cp "$marker" "$EVIDENCE/native-retry-records/worker-cwd.txt"
echo 'PASS: production bootstrap replay completed retirement; primary project remains clean'
