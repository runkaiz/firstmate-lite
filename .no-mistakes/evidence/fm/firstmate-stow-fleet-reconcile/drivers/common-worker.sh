#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/runkai/.no-mistakes/evidence/01M69TSNF6DPBES61HZAJ9RD02
RUN="$ROOT/.test-live/worker-world"
umask 022
unset FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TASK_ID FM_QUEUE_TEST_CLI TASKS_AXI_FILE TASKS_AXI_BACKEND FM_QUEUE_FILE FM_QUEUE_BACKEND
for v in "${!FM_@}"; do case "$v" in *_OVERRIDE) unset "$v" ;; esac; done
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR
mkdir -p "$RUN"
bash bin/fm-lab-home.sh create "$RUN/socket-home"
export TMUX_TMPDIR
TMUX_TMPDIR=$(bash bin/fm-lab-home.sh tmux-dir "$RUN/socket-home")
tmux -L fm-lab new-session -d -s fm-lab -x 120 -y 40 -c "$ROOT" 'bash --noprofile --norc'
export TMUX
TMUX=$(tmux -L fm-lab display-message -p -t fm-lab '#{socket_path},#{pid},0')
cleanup() {
  tmux -L fm-lab kill-server || true
  bash "$ROOT/bin/fm-lab-home.sh" teardown "$RUN/socket-home" || true
  rm -rf "$RUN"
}
trap cleanup EXIT
. "$ROOT/bin/fm-git-worktree-lib.sh"
step() { printf '\n$'; printf ' %q' "$@"; printf '\n'; "$@"; }
check() { "$@" || { printf 'ASSERTION FAILED:'; printf ' %q' "$@"; exit 1; }; }
refuse() {
  printf '\nEXPECTED REFUSAL:'; printf ' %q' "$@"; printf '\n'
  if "$@"; then echo 'ERROR: unexpectedly accepted'; exit 1; fi
  check test -d "$WT"
  check test -f "$FM_HOME/state/$ID.meta"
  check test -f "$FM_HOME/state/$ID.git-worktree"
}
commit() { printf '%s\n' "$3" > "$1/$2"; git -C "$1" add "$2"; git -C "$1" commit -qm "$4"; }
case_home() {
  ID=$1; KIND=${2:-ship}; CASE="$RUN/$ID"; PROJ="$CASE/project"
  export FM_HOME="$CASE/home"
  step bash "$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
  git init -q -b main "$PROJ"
  commit "$PROJ" seed seed initial
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'git\n' > "$FM_HOME/config/worktree-allocator"
  printf '%s\n' "$CASE/copies" > "$FM_HOME/config/git-worktree-root"
  printf 'markdown\n' > "$FM_HOME/config/backlog-backend"
  printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\ndone_keep = 100\n' > "$FM_HOME/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n- **%s** - Live %s exercise. (kind: %s)\n\n## Queued\n\n## Done\n' "$ID" "$ID" "$KIND" > "$FM_HOME/data/backlog.md"
  fm_git_worktree_allocate "$FM_HOME/state" "$ID" "$FM_HOME" "$PROJ" "$CASE/copies" "$BASE" refs/heads/main
  WT=$FM_GIT_WORKTREE_PATH
  printf 'window=fm-lab:fm-%s\nendpoint_task_id=%s\nbackend=tmux\nworktree=%s\nproject=%s\nkind=%s\nspawn_gen=s1.%s\nallocator=git\n' "$ID" "$ID" "$WT" "$PROJ" "$KIND" "$ID" > "$FM_HOME/state/$ID.meta"
  if [ "$KIND" = ship ]; then printf 'mode=local-only\nbranch=fm/%s\n' "$ID" >> "$FM_HOME/state/$ID.meta"; fi
  bash "$ROOT/bin/fm-queue.sh" show "$ID" >/dev/null
}
td() { step bash "$ROOT/bin/fm-teardown.sh" "$ID" "$@"; }
closed() {
  step bash "$ROOT/bin/fm-queue.sh" show "$ID"
  bash "$ROOT/bin/fm-queue.sh" show "$ID" | grep -q 'state: done'
  check test ! -e "$WT"
  check test ! -e "$FM_HOME/state/$ID.meta"
  check test ! -e "$FM_HOME/state/$ID.git-worktree"
  check test ! -e "$FM_HOME/state/$ID.backlog-close"
  cat "$FM_HOME/data/backlog.md"
}
fingerprint() {
  python3 - "$FM_HOME" "$PROJ" <<'PY'
import hashlib, pathlib, subprocess, sys
h=hashlib.sha256()
for part in ['state', 'data', 'config']:
 for p in sorted((pathlib.Path(sys.argv[1])/part).rglob('*')):
  if p.is_file(): h.update(str(p).encode()); h.update(p.read_bytes())
h.update(subprocess.check_output(['git','-C',sys.argv[2],'show-ref']))
print(h.hexdigest())
PY
}
