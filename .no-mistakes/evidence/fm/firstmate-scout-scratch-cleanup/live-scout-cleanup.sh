#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/runkai/.no-mistakes/evidence/01M87RH3JA5P9H2JK2DRB55G61
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
unset GIT_DIR GIT_WORK_TREE GIT_INDEX_FILE GIT_COMMON_DIR FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TASK_ID TASKS_AXI_FILE TASKS_AXI_BACKEND
for v in ${!FM_@}; do case "$v" in *_OVERRIDE) unset "$v" ;; esac; done
export TMPDIR="$ROOT/.test-tmp"
RUN=$(mktemp -d "$TMPDIR/scout-live.XXXXXX")
SOCKET=.test-tmp/scout-live.sock
export TMUX="$SOCKET,0,0"
child=
cleanup() {
  if [ -n "$child" ]; then kill "$child" 2>/dev/null || true; wait "$child" 2>/dev/null || true; fi
  tmux -S "$SOCKET" kill-server 2>/dev/null || true
  rm -rf "$RUN"
  rm -f "$ROOT/bin/.test-baseline-teardown.sh"
}
trap cleanup EXIT
git show 220db688bdded7976780f853ae8d41e77e733bca:bin/fm-teardown.sh > "$ROOT/bin/.test-baseline-teardown.sh"
# Relative socket stays in the worktree and avoids Linux's socket-path length limit.
tmux -f /dev/null -S "$SOCKET" new-session -d -s fm-lab-scout -n anchor -x 100 -y 30 -c "$ROOT" 'bash --noprofile --norc'
. "$ROOT/bin/fm-git-worktree-lib.sh"
fail() { printf 'FAIL: %s\n' "$*"; exit 1; }
setup() {
  name=$1; id="scout-$name"; CASE="$RUN/$name"; mkdir -p "$CASE"
  export FM_HOME="$CASE/home"
  bash bin/fm-lab-home.sh create "$FM_HOME"
  PROJ="$CASE/project"; mkdir -p "$PROJ"
  git -C "$PROJ" init -q -b main
  printf 'base line\n' > "$PROJ/README.md"
  printf '#!/bin/sh\nprintf base\n' > "$PROJ/tool.sh"
  printf 'old\n' > "$PROJ/rename me.txt"
  printf 'delete me\n' > "$PROJ/delete.txt"
  python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(bytes(range(256))*4)' "$PROJ/blob.bin"
  git -C "$PROJ" add .; git -C "$PROJ" commit -qm base
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  printf 'manual\n' > "$FM_HOME/config/backlog-backend"
  printf 'git\n' > "$FM_HOME/config/worktree-allocator"
  printf '%s\n' "$CASE/copies" > "$FM_HOME/config/git-worktree-root"
  fm_git_worktree_allocate "$FM_HOME/state" "$id" "$FM_HOME" "$PROJ" "$CASE/copies" "$BASE" refs/heads/main
  WT=$FM_GIT_WORKTREE_PATH
  META="$FM_HOME/state/$id.meta"; DATA="$FM_HOME/data/$id"; mkdir -p "$DATA"
  cat > "$META" <<EOF
window=fm-lab-scout:fm-$id
endpoint_task_id=$id
backend=tmux
worktree=$WT
project=$PROJ
kind=scout
mode=local-only
spawn_gen=s1792922400.123.456
allocator=git
decisions_reviewed=1
EOF
  printf 'done: report delivered\n' > "$FM_HOME/state/$id.status"
  printf '# Scout findings\nNo outstanding captain decisions.\n' > "$DATA/report.md"
  printf 'staged scratch\n' >> "$WT/README.md"
  git -C "$WT" add README.md
  printf 'unstaged scratch\n' >> "$WT/README.md"
}
manifest() {
  python3 - "$1" <<'PYS'
import os,sys,hashlib,json
from pathlib import Path
root=Path(sys.argv[1]); result=[]
for parent,dirs,files in os.walk(root):
    dirs[:]=sorted(d for d in dirs if d != '.git')
    for f in sorted(files):
        path=Path(parent)/f
        if path.name == '.git': continue
        result.append([str(path.relative_to(root)),path.lstat().st_mode,os.readlink(path) if path.is_symlink() else hashlib.sha256(path.read_bytes()).hexdigest()])
print(json.dumps(result,sort_keys=True))
PYS
}
snapshot() {
  git -C "$WT" diff --binary --no-ext-diff
  git -C "$WT" diff --cached --binary --no-ext-diff
  git -C "$WT" ls-files --stage
  manifest "$WT"
}
drive() {
  local script=${1:-bin/fm-teardown.sh}
  rc=0
  bash "$script" "$id" > "$EVIDENCE/$name.cli.log" 2>&1 || rc=$?
  printf '\nCASE %s: exit %s\n' "$name" "$rc"
  cat "$EVIDENCE/$name.cli.log"
}
refused() {
  local expected=$1
  [ "$rc" != 0 ] || fail "$name unexpectedly succeeded"
  grep -F -- "$expected" "$EVIDENCE/$name.cli.log" >/dev/null || fail "$name wrong refusal"
  snapshot > "$CASE/after"
  cmp "$CASE/before" "$CASE/after" || fail "$name changed scratch"
  [ -f "$META" ] && [ -f "$FM_HOME/state/$id.git-worktree" ] && [ -d "$WT" ] || fail "$name lost ownership"
  printf 'VERIFIED: refused; tracked bytes, index, copy and ownership retained.\n'
}
setup baseline
snapshot > "$CASE/before"
drive bin/.test-baseline-teardown.sh
refused 'tracked changes are unique work'
setup recover
# Stage binary edits, rename, deletion, mode changes, and a new tracked file.
python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"staged\x00"+bytes(range(255,-1,-1)))' "$WT/blob.bin"
git -C "$WT" mv 'rename me.txt' 'renamed file.txt'
git -C "$WT" rm -q delete.txt
chmod +x "$WT/tool.sh"
printf 'new staged\n' > "$WT/new file.txt"
git -C "$WT" add .
python3 -c 'import pathlib,sys; pathlib.Path(sys.argv[1]).write_bytes(b"unstaged\x00"+bytes(range(256)))' "$WT/blob.bin"
printf 'unstaged new\n' >> "$WT/new file.txt"
EXPECTED_TREE=$(git -C "$WT" write-tree)
manifest "$WT" > "$CASE/expected-manifest.json"
# Real idle shell endpoint in a private server; task control must close only it.
tmux -S "$SOCKET" new-window -d -t fm-lab-scout -n "fm-$id" -c "$WT" 'bash --noprofile --norc'
drive
[ "$rc" = 0 ] || fail 'finished scout could not retire'
[ ! -e "$WT" ] && [ ! -e "$META" ] && [ ! -e "$FM_HOME/state/$id.git-worktree" ] || fail 'cleanup incomplete'
[ -f "$DATA/report.md" ] || fail 'report lost'
! tmux -S "$SOCKET" list-windows -t fm-lab-scout -F '#{window_name}' | grep -Fx "fm-$id" || fail 'task endpoint retained'
tmux -S "$SOCKET" has-session -t fm-lab-scout || fail 'neighbor anchor lost'
PATCHES=("$DATA"/scratch/teardown.*)
[ "${#PATCHES[@]}" = 1 ] || fail 'missing archive'
RECOVER="$CASE/recovery"
git -C "$PROJ" worktree add -q --detach "$RECOVER" "$BASE"
git -C "$RECOVER" apply --index "${PATCHES[0]}/staged.patch"
[ "$(git -C "$RECOVER" write-tree)" = "$EXPECTED_TREE" ] || fail 'index restoration differs'
git -C "$RECOVER" apply "${PATCHES[0]}/unstaged.patch"
manifest "$RECOVER" > "$CASE/restored-manifest.json"
cmp "$CASE/expected-manifest.json" "$CASE/restored-manifest.json" || fail 'restored files differ'
mkdir -p "$EVIDENCE/recovered-scratch"
cp "${PATCHES[0]}"/*.patch "$DATA/report.md" "$EVIDENCE/recovered-scratch/"
cp "$CASE/expected-manifest.json" "$EVIDENCE/recovered-scratch/expected-manifest.json"
printf 'VERIFIED: report retained; task endpoint and records retired; neighbor survives; staged tree %s and all working bytes/modes restored from patches.\n' "$EXPECTED_TREE"
for scenario in no-report no-inventory unfinished committed ignored untracked conflicted blocked-archive foreign-process ship force; do
  setup "$scenario"
  expected=
  case "$scenario" in
    no-report) rm "$DATA/report.md"; expected='has no report' ;;
    no-inventory) sed -i '/^decisions_reviewed=/d' "$META"; expected='has not passed the captain-call completion gate' ;;
    unfinished) printf 'working: investigating\n' > "$FM_HOME/state/$id.status"; expected='has not reported completion' ;;
    committed)
      git -C "$WT" commit --allow-empty --only -qm task-commit
      git -C "$PROJ" merge --ff-only -q "$(git -C "$WT" rev-parse HEAD)"
      expected='recorded base' ;;
    ignored) printf 'ignored.log\n' > "$PROJ/.git/info/exclude"; printf 'retain me\n' > "$WT/ignored.log"; expected='untracked, ignored, or unmerged paths' ;;
    untracked) printf 'retain me\n' > "$WT/unknown.txt"; expected='untracked, ignored, or unmerged paths' ;;
    conflicted)
      blob=$(git -C "$WT" rev-parse HEAD:README.md)
      printf '100644 %s 1\tREADME.md\n100644 %s 2\tREADME.md\n100644 %s 3\tREADME.md\n' "$blob" "$blob" "$blob" | git -C "$WT" update-index --index-info
      expected='untracked, ignored, or unmerged paths' ;;
    blocked-archive) printf 'existing evidence\n' > "$DATA/scratch"; expected='could not preserve tracked scout scratch' ;;
    foreign-process)
      bash -c 'cd "$1"; printf ready > "$2"; exec sleep 120' _ "$WT" "$CASE/ready" & child=$!
      for i in $(seq 1 100); do [ ! -f "$CASE/ready" ] || break; sleep .02; done
      [ -f "$CASE/ready" ] || fail 'process did not start'
      expected='native copy still has processes' ;;
    ship) sed -i 's/kind=scout/kind=ship/' "$META"; expected='tracked changes are unique work' ;;
    force) expected='native allocator never force-discards a copy' ;;
  esac
  snapshot > "$CASE/before"
  if [ "$scenario" = force ]; then
    rc=0; bash bin/fm-teardown.sh "$id" --force > "$EVIDENCE/$name.cli.log" 2>&1 || rc=$?
    printf '\nCASE %s: exit %s\n' "$name" "$rc"; cat "$EVIDENCE/$name.cli.log"
  else drive; fi
  refused "$expected"
  if [ "$scenario" = foreign-process ]; then
    kill -0 "$child" || fail 'foreign process killed'
    kill "$child"; wait "$child" 2>/dev/null || true; child=
    printf 'VERIFIED: foreign process was alive after refusal.\n'
  fi
  if [ "$scenario" = blocked-archive ]; then
    [ "$(cat "$DATA/scratch")" = 'existing evidence' ] || fail 'archive obstruction overwritten'
    rm "$DATA/scratch"; name=archive-retry; drive
    [ "$rc" = 0 ] && [ ! -d "$WT" ] && [ -f "$DATA/report.md" ] || fail 'retry failed'
    printf 'VERIFIED: retry succeeds after archive obstruction is removed.\n'
  fi
done
printf '\nALL LIVE SCENARIOS PASSED; disposable homes and private tmux server cleaned on exit.\n'
