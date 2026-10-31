#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/runkai/.no-mistakes/evidence/01M69TSNF6DPBES61HZAJ9RD02
RUN="$ROOT/.test-live/world"
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

case_home retained
git -C "$WT" switch -qc "fm/$ID"
commit "$WT" kept kept 'unmerged work'
HEAD_KEPT=$(git -C "$WT" rev-parse HEAD)
refuse td
printf 'dirt\n' >> "$WT/kept"
refuse td --retain-branch
git -C "$WT" restore kept
td --retain-branch
closed
step git -C "$PROJ" show-ref
check test "$(git -C "$PROJ" rev-parse refs/firstmate/retained-work/$ID)" = "$HEAD_KEPT"
check test "$(git -C "$PROJ" rev-parse main)" = "$BASE"
echo 'SCENARIO PASS: explicit retention preserves both refs and automatically closes the queue'

for KIND in scout ship; do
  case_home "archive-$KIND" "$KIND"
  mkdir "$CASE/archive"
  mv "$FM_HOME/state/$ID.meta" "$CASE/archive/$ID.meta"
  sum=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CASE/archive/$ID.meta")
  before=$(fingerprint)
  step bash "$ROOT/bin/fm-reconcile-underway.sh" --archive "$CASE/archive"
  check test "$(fingerprint)" = "$before"
  step bash "$ROOT/bin/fm-task-record-restore.sh" "$ID" "$CASE/archive/$ID.meta" "$sum" "s1.$ID" "fm-lab:fm-$ID"
  check cmp "$CASE/archive/$ID.meta" "$FM_HOME/state/$ID.meta"
  step bash "$ROOT/bin/fm-task-record-restore.sh" "$ID" "$CASE/archive/$ID.meta" "$sum" "s1.$ID" "fm-lab:fm-$ID"
  unrelated=$(printf 'unrelated\n' | git -C "$PROJ" commit-tree "$(git -C "$PROJ" mktree </dev/null)")
  git -C "$PROJ" update-ref refs/heads/main "$unrelated"
  if [ "$KIND" = scout ]; then
    refuse td
    mkdir -p "$FM_HOME/data/$ID"; printf '# Completed report\n' > "$FM_HOME/data/$ID/report.md"
    refuse td
    step bash "$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none
  fi
  td; closed
  step git -C "$PROJ" show-ref
  check test "$(git -C "$PROJ" rev-parse refs/firstmate/retained-bases/$BASE)" = "$BASE"
  echo "SCENARIO PASS: archived $KIND record restored byte-exactly; unchanged copy retired after source rewrite"
done

case_home patch
git -C "$WT" switch -qc "fm/$ID"
commit "$WT" delivered delivered 'local work'
taskhead=$(git -C "$WT" rev-parse HEAD)
commit "$PROJ" advance advance 'new main base'
git -C "$PROJ" cherry-pick "$taskhead"
commit "$WT" unique unique 'unique work'
refuse td
git -C "$WT" reset -q --hard HEAD~1
step git -C "$WT" cherry main HEAD
td; closed
echo 'SCENARIO PASS: equivalent patch retires; unmatched local commit refuses'

case_home origin
git -C "$PROJ" update-ref refs/remotes/origin/main "$BASE"
sed -i 's@source_ref=refs/heads/main@source_ref=refs/remotes/origin/main@' "$FM_HOME/state/$ID.git-worktree"
git -C "$WT" switch -qc "fm/$ID"
commit "$WT" delivered delivered 'local main delivery'
git -C "$PROJ" merge -q --ff-only "fm/$ID"
td; closed
echo 'SCENARIO PASS: local main proves delivery for an origin-main reservation'

case_home merge-resolution
git -C "$WT" switch -qc "fm/$ID"
commit "$WT" conflict left left; left=$(git -C "$WT" rev-parse HEAD)
git -C "$PROJ" switch -qc right "$BASE"; commit "$PROJ" conflict right right
if git -C "$WT" merge right; then exit 1; fi
commit "$WT" conflict 'unique resolution' resolution
git -C "$PROJ" switch -q main
commit "$PROJ" advance advance advance
git -C "$PROJ" cherry-pick "$left"
git -C "$PROJ" merge -s ours --no-edit right
step git -C "$WT" cherry main HEAD
step bash "$ROOT/bin/fm-reconcile-underway.sh"
refuse td
check test "$(git -C "$WT" show HEAD:conflict)" = 'unique resolution'
echo 'SCENARIO PASS: equivalent ordinary patches cannot hide an unlanded merge resolution'

case_home preservation
mkdir -p "$WT/build" "$WT/.cache"
printf 'build bytes\n' > "$WT/build/output"
printf 'cache bytes\n' > "$WT/.cache/output"
printf '.cache/\n' > "$PROJ/.git/info/exclude"
tmux -L fm-lab new-window -d -t fm-lab -n "fm-$ID" -c "$WT" 'bash --noprofile --norc'
step tmux -L fm-lab display-message -p -t "fm-lab:fm-$ID" '#{pane_pid} #{pane_current_command} #{pane_current_path}'
refuse td
refuse td --preserve-untracked build
check test -f "$WT/build/output"
check test -f "$WT/.cache/output"
td --preserve-untracked build --preserve-untracked .cache
closed
step cat "$FM_HOME/data/$ID/preserved-artifacts/files/build/output" "$FM_HOME/data/$ID/preserved-artifacts/files/.cache/output"
check test "$(cat "$FM_HOME/data/$ID/preserved-artifacts/files/build/output")" = 'build bytes'
check test "$(cat "$FM_HOME/data/$ID/preserved-artifacts/files/.cache/output")" = 'cache bytes'
echo 'SCENARIO PASS: idle terminal shell closes and named untracked/ignored bytes survive cleanup'

case_home recordless scout
rm "$FM_HOME/state/$ID.meta"
mkdir -p "$FM_HOME/data/$ID"; printf '# Delivered report\n' > "$FM_HOME/data/$ID/report.md"
before=$(fingerprint)
step bash "$ROOT/bin/fm-reconcile-underway.sh"
check test "$(fingerprint)" = "$before"
step bash "$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none
before=$(fingerprint)
step bash "$ROOT/bin/fm-reconcile-underway.sh"
check test "$(fingerprint)" = "$before"
step bash "$ROOT/bin/fm-queue.sh" done "$ID" --report "data/$ID/report.md"
step bash "$ROOT/bin/fm-queue.sh" show "$ID"
check test -d "$WT"
check test -f "$FM_HOME/state/$ID.git-worktree"
echo 'SCENARIO PASS: verified recordless scout closes with report while its copy and reservation remain'

case_home held
step bash "$ROOT/bin/fm-captain-hold.sh" hold "$ID" --reason 'Awaiting an explicit decision'
before=$(fingerprint)
step bash "$ROOT/bin/fm-reconcile-underway.sh"
check test "$(fingerprint)" = "$before"
step bash "$ROOT/bin/fm-queue.sh" show "$ID"
echo 'SCENARIO PASS: reconciliation leaves captain-held work unchanged'
echo 'ALL LIVE CLI SCENARIOS PASSED'
