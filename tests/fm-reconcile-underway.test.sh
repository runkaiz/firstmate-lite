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
case "$1" in
  list-windows) printf 'main\nfm-live-local\nfm-live-scout\nfm-live-pr\n' ;;
  display-message)
    case "${*: -1}" in '#{pane_current_command}') printf 'codex\n' ;; *) exit 1 ;; esac ;;
esac
SH
cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = 'pr view' ] && { [ "$3" != 'https://github.com/fixture/project/pull/404' ] || exit 1; printf 'MERGED\n'; exit 0; }
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

row reserved-report scout
copy reserved-report
mkdir -p "$HOME_DIR/data/reserved-report"
printf '# delivered\n' > "$HOME_DIR/data/reserved-report/report.md"
row draft scout
mkdir -p "$HOME_DIR/data/draft"
printf '# draft\n' > "$HOME_DIR/data/draft/report.md"
row reserved-draft scout
copy reserved-draft
mkdir -p "$HOME_DIR/data/reserved-draft"
printf '# draft\n' > "$HOME_DIR/data/reserved-draft/report.md"
for id in reported reserved-report; do
  env FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" PATH="$FAKE:$PATH" \
    bash "$ROOT/bin/fm-captain-hold.sh" complete "$id" --none >/dev/null || fail "complete $id"
  [ ! -e "$HOME_DIR/state/$id.meta" ] || fail 'completion recreated a task record'
done
for kind in local scout pr; do
  id="live-$kind"
  row "$id" "$([ "$kind" = scout ] && printf scout || printf ship)"
  copy "$id"
  case "$kind" in
    local) meta "$id" ship mode=local-only; printf 'editing\n' > "$WT/in-progress" ;;
    scout) meta "$id" scout; mkdir -p "$HOME_DIR/data/$id"; printf '# draft\n' > "$HOME_DIR/data/$id/report.md" ;;
    pr) meta "$id" ship mode=no-mistakes pr=https://github.com/fixture/project/pull/3
      printf 'new work\n' > "$WT/after-merge" ;;
  esac
done
row unreadable ship
copy unreadable; meta unreadable ship mode=no-mistakes pr=https://github.com/fixture/project/pull/404

row merge-resolution ship
copy merge-resolution; meta merge-resolution ship mode=local-only branch=fm/merge-resolution
git -C "$WT" switch -qc fm/merge-resolution
printf 'left\n' > "$WT/conflict"; git -C "$WT" add conflict; git -C "$WT" "${GIT_ID[@]}" commit -qm left
left=$(git -C "$WT" rev-parse HEAD)
git -C "$PROJ" switch -qc right "$BASE"
printf 'right\n' > "$PROJ/conflict"; git -C "$PROJ" add conflict; git -C "$PROJ" "${GIT_ID[@]}" commit -qm right
if git -C "$WT" "${GIT_ID[@]}" merge right >/dev/null 2>&1; then fail 'expected merge conflict'; fi
printf 'unique resolution\n' > "$WT/conflict"; git -C "$WT" add conflict; git -C "$WT" "${GIT_ID[@]}" commit -qm resolution
git -C "$PROJ" switch -q "$MAIN"
printf 'advance\n' > "$PROJ/advance"; git -C "$PROJ" add advance; git -C "$PROJ" "${GIT_ID[@]}" commit -qm advance
git -C "$PROJ" "${GIT_ID[@]}" cherry-pick "$left" >/dev/null
git -C "$PROJ" "${GIT_ID[@]}" merge -s ours --no-edit right >/dev/null
cherry=$(git -C "$WT" cherry "$MAIN" HEAD)
[ -n "$cherry" ] && ! printf '%s\n' "$cherry" | grep -qv '^- ' || fail 'merge fixture lacks patch-equivalent ordinary commits'

fingerprint() {
  python3 - "$HOME_DIR" <<'PYTHON'
import hashlib, json, os, pathlib, sys
root = pathlib.Path(sys.argv[1])
records = []
def failed(error):
    raise error
for part in ("state", "data"):
    for directory, _, files in os.walk(root / part, onerror=failed):
        for name in files:
            path = pathlib.Path(directory) / name
            if path.is_symlink():
                continue
            records.append((str(path.relative_to(root)), hashlib.sha256(path.read_bytes()).hexdigest()))
print(json.dumps(sorted(records)))
PYTHON
}
cat > "$FAKE/sha256sum" <<'SH'
#!/usr/bin/env bash
exit 127
SH
chmod +x "$FAKE/sha256sum"
before=$(fingerprint) || fail 'cannot fingerprint home before classification'
out=$(env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-reconcile-underway.sh" --archive "$ARCHIVE" 2>&1)
expect_code 0 "$?" "classification failed: $out"
after=$(fingerprint) || fail 'cannot fingerprint home after classification'
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
digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "$ARCHIVE/archived.meta") || fail 'cannot hash fixture archive'
expect archived record-archived "bin/fm-task-record-restore.sh archived $ARCHIVE/archived.meta $digest s1.archived native-fixture:fm-archived"
expect orphan unretirable -
expect reported landed 'bin/fm-queue.sh done reported --report data/reported/report.md'
expect stale stale-row -
expect reserved-report landed 'bin/fm-queue.sh done reserved-report --report data/reserved-report/report.md'
assert_contains "$(line reserved-report)" 'copy and reservation stay preserved' 'reserved scout preservation missing'
expect draft needs-captain -
expect reserved-draft needs-captain -
expect live-local ongoing -
expect live-scout ongoing -
expect live-pr ongoing -
expect unreadable unknown -
expect merge-resolution needs-captain -
[ "$(printf '%s\n' "$out" | wc -l | tr -d ' ')" = 17 ] || fail "unexpected classification lines: $out"
pass 'underway work classifies as held, landed, needs-captain, ongoing, archived, unretirable and stale without mutation'

real_python=$(command -v python3)
cat > "$FAKE/python3" <<'SH'
#!/usr/bin/env bash
[ "${*: -1}" != "${FM_TEST_HASH_FAIL:?}" ] || exit 1
exec "${FM_TEST_REAL_PYTHON:?}" "$@"
SH
chmod +x "$FAKE/python3"
out=$(env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
  FM_TEST_REAL_PYTHON="$real_python" FM_TEST_HASH_FAIL="$ARCHIVE/archived.meta" \
  bash "$ROOT/bin/fm-reconcile-underway.sh" --archive "$ARCHIVE" 2>&1)
expect_code 0 "$?" "classification with unreadable hash failed: $out"
expect archived unretirable -
assert_contains "$(line archived)" 'cannot hash archived record' 'hash failure was not explained'
rm "$FAKE/python3"
pass 'archive hashing works without sha256sum and failed hashing proposes no restore'

# The proposed restore command is exactly runnable and the rerun reclassifies.
env FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-task-record-restore.sh" archived "$ARCHIVE/archived.meta" "$digest" s1.archived native-fixture:fm-archived >/dev/null \
  || fail 'proposed restore command did not run'
out=$(env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-reconcile-underway.sh" 2>&1)
expect archived ongoing 'bin/fm-control.sh archived relaunch'
pass 'a proposed restore runs as printed and the restored record reclassifies on rerun'

if env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-reconcile-underway.sh" --no-forge >/dev/null 2>&1; then
  fail 'removed forge opt-out was accepted'
fi
for id in reported reserved-report; do
  cmd=$(line "$id" | cut -f3)
  (cd "$ROOT" && env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash -c "$cmd") >/dev/null || fail "queue close failed for $id"
done
[ -f "$HOME_DIR/state/reserved-report.git-worktree" ] || fail 'queue close lost reservation'
[ -d "$(fm_git_worktree_field "$HOME_DIR/state/reserved-report.git-worktree" path)" ] || fail 'queue close lost copy'
pass 'verified record-less scout queue closure preserves native resources'

captain() { env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" bash "$ROOT/bin/fm-captain-hold.sh" "$@"; }
tasks-axi add pending fixture --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null || fail 'add pending call'
captain hold pending --reason 'choose direction' --origin reserved-draft >/dev/null || fail 'hold pending call'
captain complete reserved-draft pending >/dev/null || fail 'record report inventory'
captain verify reserved-draft >/dev/null || fail 'verify report inventory'
captain complete reserved-draft --none >/dev/null || fail 'repeat report inventory'
tasks-axi done pending --file "$HOME_DIR/data/backlog.md" >/dev/null || fail 'close pending fixture'
if captain verify reserved-draft >/dev/null 2>&1; then fail 'verification forgot the unresolved inventory entry'; fi
printf 'needs-decision [key=direction]: choose direction\n' > "$HOME_DIR/state/draft.status"
if captain complete draft --none >/dev/null 2>&1; then fail 'completion accepted an open status decision'; fi
if captain verify draft >/dev/null 2>&1; then fail 'failed completion licensed queue closure'; fi
pass 'record-less inventories retain their entries and reject unresolved captain calls'

fm_test_cleanup
