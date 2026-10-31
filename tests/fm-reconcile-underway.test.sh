#!/usr/bin/env bash
# Read-only underway-work classification and its guarded next commands.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-git-worktree-lib.sh disable=SC1091
. "$ROOT/bin/fm-git-worktree-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-reconcile-underway)
GIT_ID=(-c user.name=test -c user.email=test@example.invalid)
HOME_DIR="$TMP_ROOT/home"
PROJ="$TMP_ROOT/project"
COPY_ROOT="$TMP_ROOT/copies"
ARCHIVE="$TMP_ROOT/archive"
fm_test_spawn_home "$HOME_DIR" codex
fm_git_init_commit "$PROJ"
BASE=$(git -C "$PROJ" rev-parse HEAD)
MAIN=$(git -C "$PROJ" symbolic-ref --short HEAD)
printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
printf 'markdown\n' > "$HOME_DIR/config/backlog-backend"
fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
mkdir -p "$ARCHIVE"
FAKE=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in list-windows) printf 'main\n' ;; display-message) exit 1 ;; esac
SH
cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = 'pr view' ] && { printf 'MERGED\n'; exit 0; }
exit 1
SH
chmod +x "$FAKE/tmux" "$FAKE/gh"

row() { # <id> <kind>
  tasks-axi add "$1" fixture --kind "$2" --file "$HOME_DIR/data/backlog.md" >/dev/null || fail "could not add $1"
  tasks-axi start "$1" --file "$HOME_DIR/data/backlog.md" >/dev/null || fail "could not start $1"
}
copy() { # <id> -> WT
  fm_git_worktree_allocate "$HOME_DIR/state" "$1" "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$BASE" "refs/heads/$MAIN" || fail "allocate $1"
  WT=$FM_GIT_WORKTREE_PATH
}
meta() { # <id> <kind> [field...]
  local id=$1 kind=$2; shift 2
  fm_write_meta "$HOME_DIR/state/$id.meta" "window=native-fixture:fm-$id" "endpoint_task_id=$id" 'backend=tmux' \
    "worktree=$WT" "project=$PROJ" "kind=$kind" "spawn_gen=s1.$id" 'allocator=git' "$@"
}

row held ship
tasks-axi hold held --reason 'captain decision pending' --kind captain --file "$HOME_DIR/data/backlog.md" >/dev/null || fail 'hold'
copy held; meta held ship mode=local-only

row landed ship
copy landed; meta landed ship mode=local-only branch=fm/landed
git -C "$WT" switch -qc fm/landed
printf 'x\n' > "$WT/x"; git -C "$WT" add x; git -C "$WT" "${GIT_ID[@]}" commit -qm landed
git -C "$PROJ" merge -q --ff-only fm/landed
BASE=$(git -C "$PROJ" rev-parse HEAD)
mkdir -p "$WT/node_modules/pkg" "$WT/notes"
printf 'gen\n' > "$WT/node_modules/pkg/index.js"
printf 'evidence\n' > "$WT/notes/session.txt"

row unlanded ship
copy unlanded; meta unlanded ship mode=local-only branch=fm/unlanded
git -C "$WT" switch -qc fm/unlanded
printf 'y\n' > "$WT/y"; git -C "$WT" add y; git -C "$WT" "${GIT_ID[@]}" commit -qm unlanded

row merged ship
copy merged; meta merged ship mode=no-mistakes pr=https://github.com/fixture/project/pull/3

row gone-scout scout
copy gone-scout; meta gone-scout scout

row archived scout
copy archived; meta archived scout
mv "$HOME_DIR/state/archived.meta" "$ARCHIVE/archived.meta"

copy orphan
row reported scout
mkdir -p "$HOME_DIR/data/reported"; printf '# r\n' > "$HOME_DIR/data/reported/report.md"
row stale ship

before=$(cd "$HOME_DIR" && find state data -type f -exec sha256sum {} + | sort)
out=$(env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-reconcile-underway.sh" --archive "$ARCHIVE" 2>&1)
expect_code 0 "$?" "classification failed: $out"
after=$(cd "$HOME_DIR" && find state data -type f -exec sha256sum {} + | sort)
[ "$before" = "$after" ] || fail 'classification changed home state'
line() { printf '%s\n' "$out" | awk -F '\t' -v id="$1" '$1 == id'; }
expect() { # <id> <class> <next-substring>
  local got; got=$(line "$1")
  [ "$(printf '%s' "$got" | cut -f2)" = "$2" ] || fail "$1 classified as '$(printf '%s' "$got" | cut -f2)', expected $2: $got"
  assert_contains "$(printf '%s' "$got" | cut -f3)" "$3" "$1 next command"
}
expect held captain-held -
expect landed landed 'bin/fm-teardown.sh landed --preserve-untracked node_modules'
assert_contains "$(line landed)" 'other leftovers refuse teardown: notes' 'non-generated leftover was not flagged'
case "$(line landed | cut -f3)" in *notes*) fail 'non-generated leftover proposed for preservation' ;; esac
expect unlanded needs-captain -
expect merged landed 'bin/fm-teardown.sh merged'
expect gone-scout ongoing 'bin/fm-control.sh gone-scout relaunch'
digest=$(sha256sum "$ARCHIVE/archived.meta" | cut -d' ' -f1)
expect archived record-archived "bin/fm-task-record-restore.sh archived $ARCHIVE/archived.meta $digest s1.archived native-fixture:fm-archived"
expect orphan unretirable -
expect reported landed 'bin/fm-queue.sh done reported --report data/reported/report.md'
expect stale stale-row -
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 9 ] || fail "unexpected classification lines: $out"
pass 'underway work classifies as held, landed, needs-captain, ongoing, archived, unretirable and stale without mutation'

# The proposed restore command is exactly runnable and the rerun reclassifies.
env FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-task-record-restore.sh" archived "$ARCHIVE/archived.meta" "$digest" s1.archived native-fixture:fm-archived >/dev/null \
  || fail 'proposed restore command did not run'
out=$(env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-reconcile-underway.sh" 2>&1)
expect archived ongoing 'bin/fm-control.sh archived relaunch'
pass 'a proposed restore runs as printed and the restored record reclassifies on rerun'

fm_test_cleanup
