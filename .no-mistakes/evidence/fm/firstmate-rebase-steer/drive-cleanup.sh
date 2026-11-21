#!/usr/bin/env bash
# Run from the gate worktree. Uses real Git, tmux, queue, and teardown commands.
set -euo pipefail
ROOT=$PWD
AREA="$ROOT/.test-cleanup-tmp/live"
EVIDENCE=/home/runkai/.no-mistakes/evidence/01M802FN83P0KK3GS6SKC80VSE
for var in "${!FM_@}"; do unset "$var"; done
unset TMUX TASKS_AXI_FILE TASKS_AXI_BACKEND FM_QUEUE_FILE FM_QUEUE_BACKEND
export NO_MISTAKES_GATE=1 GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
export GIT_AUTHOR_NAME=Lab GIT_AUTHOR_EMAIL=lab@example.invalid
export GIT_COMMITTER_NAME=Lab GIT_COMMITTER_EMAIL=lab@example.invalid
mkdir -p "$AREA/tmp" "$EVIDENCE/tmux"
export TMPDIR="$AREA/tmp"
# The evidence directory is short enough for a Unix socket. The worktree's
# physical path exceeds tmux's socket-name limit. Remove this transport on exit.
export TMUX_TMPDIR="$EVIDENCE/tmux"
cleanup() {
  tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf -- "$EVIDENCE/tmux"
  rm -rf -- "$AREA"
}
trap cleanup EXIT
tmux -L fm-lab -f /dev/null new-session -d -s fm-lab-cleanup -n main -x 120 -y 35 -c "$ROOT" 'sleep 1200'
export TMUX
TMUX=$(tmux -L fm-lab display-message -p -t fm-lab-cleanup '#{socket_path},#{pid},0')
printf 'Private tmux inventory: '
tmux list-windows -t '=fm-lab-cleanup' -F '#{window_name}'
bash "$ROOT/bin/fm-lab-home.sh" create "$AREA/home"
export FM_HOME="$AREA/home"
PROJ="$AREA/project"
mkdir -p "$PROJ/web" "$PROJ/scripts" "$AREA/copies"
git -C "$PROJ" init -qb main
printf 'initial\n' > "$PROJ/README.md"
printf '{}\n' > "$PROJ/web/package.json"
printf '# source\n' > "$PROJ/scripts/main.py"
printf '/build/\n/dist/\n/out/\n/target/\n/.cache/\n__pycache__/\n' > "$PROJ/.gitignore"
printf '/node_modules/\n/.next/\n/out/\n/next-env.d.ts\n' > "$PROJ/web/.gitignore"
git -C "$PROJ" add .
git -C "$PROJ" commit -qm 'project with tracked ignore rules'
printf 'git\n' > "$FM_HOME/config/worktree-allocator"
printf '%s\n' "$AREA/copies" > "$FM_HOME/config/git-worktree-root"
printf 'markdown\n' > "$FM_HOME/config/backlog-backend"
printf 'backend = "markdown"\n' > "$FM_HOME/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n- **fix-one** - First landed fix.\n- **fix-two** - Second landed fix.\n- **guard** - Guarded cleanup.\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
. "$ROOT/bin/fm-git-worktree-lib.sh"
allocate() {
  ID=$1
  local base
  base=$(git -C "$PROJ" rev-parse main)
  fm_git_worktree_allocate "$FM_HOME/state" "$ID" "$FM_HOME" "$PROJ" "$AREA/copies" "$base" refs/heads/main
  WT=$FM_GIT_WORKTREE_PATH
  git -C "$WT" switch -qc "fm/$ID"
  printf '%s delivered\n' "$ID" > "$WT/$ID.txt"
  git -C "$WT" add "$ID.txt"
  git -C "$WT" commit -qm "$ID implementation"
  git -C "$PROJ" merge --ff-only "fm/$ID"
  cat > "$FM_HOME/state/$ID.meta" <<EOF
window=fm-lab-cleanup:fm-$ID
endpoint_task_id=$ID
backend=tmux
worktree=$WT
project=$PROJ
kind=ship
mode=local-only
branch=fm/$ID
spawn_gen=s1792922400.123.456
allocator=git
EOF
  printf 'done [at=1792922400]: delivered locally\n' > "$FM_HOME/state/$ID.status"
}
queue() { bash "$ROOT/bin/fm-queue.sh" show "$ID"; }
teardown() { bash "$ROOT/bin/fm-teardown.sh" "$ID"; }
retain() {
  test -d "$WT" && test -f "$FM_HOME/state/$ID.meta" && test -f "$FM_HOME/state/$ID.git-worktree"
  test ! -e "$FM_HOME/data/$ID/preserved-artifacts"
  queue
}
refuse() {
  printf '\nATTEMPT: %s\n' "$1"
  local rc=0
  teardown || rc=$?
  printf 'Teardown exit: %s\n' "$rc"
  test "$rc" -ne 0
  retain
}
verify_preserved() {
  python3 - "$FM_HOME/data/$ID/preserved-artifacts" "$1" <<'PY'
import hashlib, json, pathlib, sys
root = pathlib.Path(sys.argv[1])
expected = json.loads(pathlib.Path(sys.argv[2]).read_text())
for rel, digest in expected.items():
    path = root / 'files' / rel
    assert hashlib.sha256(path.read_bytes()).hexdigest() == digest, rel
print('Preserved exact bytes:', ', '.join(sorted(expected)))
print('Preservation receipt:')
print((root / 'receipt').read_text())
PY
  test ! -e "$WT"
  test ! -e "$FM_HOME/state/$ID.meta"
  test ! -e "$FM_HOME/state/$ID.git-worktree"
  test "$(git -C "$PROJ" rev-parse "fm/$ID")" = "$(git -C "$PROJ" rev-parse main)"
  queue
}
snapshot() {
  python3 - "$WT" "$AREA/$ID.json" <<'PY'
import hashlib, json, pathlib, subprocess, sys
root = pathlib.Path(sys.argv[1])
paths = subprocess.check_output(['git', '-C', str(root), 'ls-files', '--others', '-z']).split(b'\0')
data = {p.decode(): hashlib.sha256((root / p.decode()).read_bytes()).hexdigest() for p in paths if p}
pathlib.Path(sys.argv[2]).write_text(json.dumps(data))
print('Original generated-file hashes:', json.dumps(data, sort_keys=True))
PY
}
allocate fix-one
mkdir -p "$WT/build/lib" "$WT/.cache" "$WT/web/node_modules/pkg" "$WT/web/.next" "$WT/web/out" "$WT/scripts/__pycache__"
printf 'object\n' > "$WT/build/lib/main.o"
printf 'cache\n' > "$WT/.cache/state"
printf 'module\n' > "$WT/web/node_modules/pkg/index.js"
printf 'next build\n' > "$WT/web/.next/server.js"
printf '<html>page</html>\n' > "$WT/web/out/index.html"
printf 'generated types\n' > "$WT/web/next-env.d.ts"
printf 'bytecode\n' > "$WT/scripts/__pycache__/main.pyc"
snapshot
queue
# Counterfactual: run the unchanged product with only the base revision's
# changed library, against the very same landed task and generated files.
mkdir -p "$AREA/base"
cp -R "$ROOT/bin" "$AREA/base/bin"
git show c9f7d4df2536d78656512fb50488ee1f4f776a6a:bin/fm-git-worktree-lib.sh > "$AREA/base/bin/fm-git-worktree-lib.sh"
printf '\nBASELINE: the same cleanup before this change\n'
rc=0
bash "$AREA/base/bin/fm-teardown.sh" "$ID" || rc=$?
test "$rc" -ne 0
retain
printf '\nTARGET: one cleanup call for the first landed fix\n'
teardown
verify_preserved "$AREA/$ID.json"

allocate fix-two
mkdir -p "$WT/build" "$WT/dist" "$WT/out" "$WT/target" "$WT/web/out"
for rel in build/app dist/app out/app target/app web/out/app; do printf 'generated %s\n' "$rel" > "$WT/$rel"; done
printf 'types\n' > "$WT/web/next-env.d.ts"
snapshot
printf '\nTARGET: one cleanup call for the second landed fix\n'
teardown
verify_preserved "$AREA/$ID.json"

allocate guard
mkdir -p "$WT/build" "$WT/web/out"
printf 'generated\n' > "$WT/build/app.o"
printf 'generated page\n' > "$WT/web/out/index.html"
printf 'scratch\n' > "$WT/notes.txt"
refuse 'unknown untracked notes mixed with ignored output'
test "$(cat "$WT/notes.txt")" = scratch
rm "$WT/notes.txt"
printf 'tracked edit\n' >> "$WT/README.md"
refuse 'tracked edit mixed with ignored output'
git -C "$WT" checkout -q -- README.md
mkdir "$WT/web/dist"
printf 'unique web dist\n' > "$WT/web/dist/notes"
refuse 'root /dist/ ignore must not authorize web/dist'
rm -r "$WT/web/dist"
printf 'unique type file\n' > "$WT/next-env.d.ts"
refuse 'unignored next-env.d.ts must remain'
rm "$WT/next-env.d.ts"
mv "$WT/build" "$AREA/real-build"
ln -s "$AREA/real-build" "$WT/build"
refuse 'ignored build name is a symlink'
test -L "$WT/build"
rm "$WT/build"
mv "$AREA/real-build" "$WT/build"
git -C "$WT/build" init -q
printf 'unique nested repo\n' > "$WT/build/unique"
git -C "$WT/build" add unique
git -C "$WT/build" commit -qm 'nested unique work'
refuse 'ignored build contains a nested repository with a unique commit'
git -C "$WT/build" show HEAD:unique
rm -rf "$WT/build/.git" "$WT/build/unique"
printf 'unlanded\n' > "$WT/unlanded.txt"
git -C "$WT" add unlanded.txt
git -C "$WT" commit -qm 'unlanded followup'
refuse 'generated leftovers cannot authorize an unlanded commit'
test "$(git -C "$WT" show HEAD:unlanded.txt)" = unlanded
printf '\nLand the followup through ordinary fast-forward, then retry cleanup\n'
git -C "$PROJ" merge --ff-only "fm/$ID"
snapshot
teardown
verify_preserved "$AREA/$ID.json"
printf '\nFinal queue:\n'
bash "$ROOT/bin/fm-queue.sh" list
printf '\nAll live scenarios completed; disposing private tmux and lab home.\n'
