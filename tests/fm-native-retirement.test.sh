#!/usr/bin/env bash
# Guarded retirement of retained native copies whose work is proven landed or
# kept: archived scout records, replaced source history, patch-equivalent
# local-only delivery, pipeline-rewritten merged PRs, and branch-kept commits.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-git-worktree-lib.sh disable=SC1091
. "$ROOT/bin/fm-git-worktree-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-native-retirement)
GIT_ID=(-c user.name=test -c user.email=test@example.invalid)

# One home, one project, one native copy with a gone tmux endpoint.
make_case() { # <name> <kind> <mode-or-empty>
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  COPY_ROOT="$CASE/copies"
  ID="retire-$1"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_init_commit "$PROJ"
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  MAIN=$(git -C "$PROJ" symbolic-ref --short HEAD)
  printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
  printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  fm_git_worktree_allocate "$HOME_DIR/state" "$ID" "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$BASE" "refs/heads/$MAIN" \
    || fail "$1 allocation failed"
  WT=$FM_GIT_WORKTREE_PATH
  FAKE=$(fm_fakebin "$CASE/fake")
  cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in list-windows) printf 'main\n' ;; display-message) exit 1 ;; esac
SH
  cat > "$FAKE/gh" <<'SH'
#!/usr/bin/env bash
[ "$1 $2" = 'pr view' ] || exit 1
printf '%s\t%s\t%s\n' "${FM_TEST_PR_STATE:-MERGED}" "${FM_TEST_PR_HEAD:?}" https://github.com/fixture/project/pull/7
SH
  cat > "$FAKE/no-mistakes" <<'SH'
#!/usr/bin/env bash
[ "$*" = 'axi sync --check' ] && [ -n "${FM_TEST_SYNC_FILE:-}" ] && cat "$FM_TEST_SYNC_FILE"
exit 0
SH
  chmod +x "$FAKE/tmux" "$FAKE/gh" "$FAKE/no-mistakes"
  local fields=("window=native-fixture:fm-$ID" "endpoint_task_id=$ID" 'backend=tmux'
    "worktree=$WT" "project=$PROJ" "kind=$2" 'spawn_gen=s1792922400.123.456' 'allocator=git')
  [ -z "$3" ] || fields+=("mode=$3" "branch=fm/$ID")
  fm_write_meta "$HOME_DIR/state/$ID.meta" "${fields[@]}"
}

teardown() {
  env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 \
    bash "$ROOT/bin/fm-teardown.sh" "$ID" "$@"
}

commit_in() { # <dir> <file> <content> <message>
  printf '%s\n' "$3" > "$1/$2"
  git -C "$1" add "$2"
  git -C "$1" "${GIT_ID[@]}" commit -qm "$4"
}

retained() { [ -d "$WT" ] && [ -f "$HOME_DIR/state/$ID.meta" ] && [ -f "$HOME_DIR/state/$ID.git-worktree" ]; }
retired() { [ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$ID.meta" ] && [ ! -e "$HOME_DIR/state/$ID.git-worktree" ]; }

automatic_backlog() {
  printf 'markdown\n' > "$HOME_DIR/config/backlog-backend"
  printf 'backend = "markdown"\n' > "$HOME_DIR/.tasks.toml"
  printf '# Backlog\n\n## In flight\n\n- **%s** - Retire copy.\n\n## Queued\n\n## Done\n' "$ID" > "$HOME_DIR/data/backlog.md"
}

assert_closed_note() {
  local out
  out=$(env FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-queue.sh" show "$ID") || fail "queue read failed: $out"
  assert_contains "$out" 'state: done' 'retirement did not close the queue row'
  assert_contains "$out" "$1" 'completion lost the exact delivery note'
  [ ! -e "$HOME_DIR/state/$ID.backlog-close" ] || fail 'completion left a pending close'
}

# Exercise the persisted close protocol independently of copy removal, including
# replay after a crash and retry after the queue has already closed the row.
replay_note() {
  # shellcheck disable=SC2016 # positional parameters expand in the child shell
  env FM_HOME="$HOME_DIR" bash -c '
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_close_marker_replay "$FM_HOME/state" "$FM_HOME/state/$2.backlog-close" "$FM_HOME/data" || {
      printf "%s\n" "$FM_BACKLOG_TRANSITION_ERROR" >&2
      exit 1
    }
  ' bash "$ROOT" "$ID"
}

head=$(printf '%040d' 1)
ID=retire-note
for note in "landed via https://github.com/fixture/project/pull/7 at $head" \
  "copy retired unlanded; commits retained on refs/heads/kept%20branch and refs/firstmate/retained-work/$ID at $head" \
  'local main'; do
  HOME_DIR="$TMP_ROOT/note-home"
  fm_test_spawn_home "$HOME_DIR" codex
  automatic_backlog
  # shellcheck disable=SC2016 # positional parameters expand in the child shell
  out=$(env FM_HOME="$HOME_DIR" bash -c '
    . "$1/bin/fm-tasks-axi-lib.sh"
    . "$1/bin/fm-backlog-transition-lib.sh"
    fm_backlog_close_marker_write "$FM_HOME/state" "$2" "$FM_HOME/data" note-generation --note "$3" || {
      printf "%s\n" "$FM_BACKLOG_TRANSITION_ERROR" >&2
      exit 1
    }
  ' bash "$ROOT" "$ID" "$note" 2>&1) || fail "note could not be serialized: $note: $out"
  cp "$HOME_DIR/state/$ID.backlog-close" "$TMP_ROOT/saved-close"
  replay_note || fail "note replay failed: $note"
  assert_closed_note "$note"
  cp "$TMP_ROOT/saved-close" "$HOME_DIR/state/$ID.backlog-close"
  replay_note || fail "repeated note replay failed: $note"
  assert_closed_note "$note"
done
pass 'sibling-PR, retained-branch and legacy local-main notes survive serialization and repeated replay'

for note in "landed via https://github.com/fixture/project/pull/7 at short" \
  "landed via https://github.com/fixture/project/pull/0 at $head" \
  "copy retired unlanded; commits retained on refs/heads/bad..branch and refs/firstmate/retained-work/$ID at $head" \
  "copy retired unlanded; commits retained on refs/heads/kept and refs/firstmate/retained-work/another-task at $head" \
  'arbitrary completion claim'; do
  automatic_backlog
  before=$(cat "$HOME_DIR/data/backlog.md")
  marker="$HOME_DIR/state/$ID.backlog-close"
  printf 'id=%s\ndata=%s\nspawn_gen=note-generation\narg=--note\narg=%s\n' \
    "$ID" "$HOME_DIR/data" "$note" > "$marker"
  if out=$(replay_note 2>&1); then fail "invalid completion note replayed: $note"; fi
  assert_contains "$out" 'invalid pending-close arguments' 'invalid note refused for the wrong reason'
  [ -f "$marker" ] || fail 'invalid note replay removed its marker'
  [ "$(cat "$HOME_DIR/data/backlog.md")" = "$before" ] || fail 'invalid note replay changed the queue'
done
pass 'malformed and foreign completion notes refuse without changing the queue or consuming the marker'

# A + B: archived scout record whose recorded source was replaced by unrelated
# history, with no task commits (audit: validation-overhead-audit).
make_case scout scout ''
mv "$HOME_DIR/state/$ID.meta" "$CASE/archived.meta"
digest=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CASE/archived.meta")
restore() { env FM_HOME="$HOME_DIR" bash "$ROOT/bin/fm-task-record-restore.sh" "$ID" "$1" "$2" s1792922400.123.456 "native-fixture:fm-$ID"; }
{ cat "$CASE/archived.meta"; printf 'mode=no-mistakes\n'; } > "$CASE/moded.meta"
moded=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1],"rb").read()).hexdigest())' "$CASE/moded.meta")
if out=$(restore "$CASE/moded.meta" "$moded" 2>&1); then fail 'scout record naming a delivery contract was restored'; fi
assert_contains "$out" 'scout record names a delivery contract' 'moded scout refused for the wrong reason'
restore "$CASE/archived.meta" "$digest" || fail 'archived scout record could not be restored'
cmp "$CASE/archived.meta" "$HOME_DIR/state/$ID.meta" || fail 'scout restore changed record bytes'
unrelated=$(printf 'replaced history\n' | git -C "$PROJ" "${GIT_ID[@]}" commit-tree "$(git -C "$PROJ" mktree </dev/null)")
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$unrelated"
if teardown >/dev/null 2>&1; then fail 'scout without its report was retired'; fi
retained || fail 'scout report refusal lost the copy'
mkdir -p "$HOME_DIR/data/$ID"
printf '# report\n' > "$HOME_DIR/data/$ID/report.md"
env FM_ROOT_OVERRIDE="$ROOT" FM_HOME="$HOME_DIR" PATH="$FAKE:$PATH" \
  "$ROOT/bin/fm-captain-hold.sh" complete "$ID" --none >/dev/null || fail 'could not record scout inventory'
out=$(teardown 2>&1)
expect_code 0 "$?" "restored scout with replaced source was not retired: $out"
retired || fail 'scout retirement left the copy or records'
[ "$(git -C "$PROJ" rev-parse "refs/firstmate/retained-bases/$BASE")" = "$BASE" ] || fail 'scout base left Git custody'
pass 'archived scout record restores byte-exactly and an unchanged copy retires despite replaced source history'

# B for local-only: no task commits, recorded local source replaced.
make_case unchanged ship local-only
unrelated=$(printf 'replaced history\n' | git -C "$PROJ" "${GIT_ID[@]}" commit-tree "$(git -C "$PROJ" mktree </dev/null)")
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$unrelated"
out=$(teardown 2>&1)
expect_code 0 "$?" "unchanged local-only copy with replaced source was not retired: $out"
retired || fail 'unchanged local-only retirement left resources'
[ "$(git -C "$PROJ" rev-parse "refs/firstmate/retained-bases/$BASE")" = "$BASE" ] || fail 'local-only base left Git custody'
pass 'unchanged local-only copy retires with its base retained when the source history was replaced'

# D: local-only work delivered as an identical patch with another commit id
# (squash-merged sibling PR then local main reset; audit: 3d9a2fcd vs 5d0ec5e4).
make_case patch ship local-only
git -C "$WT" switch -qc "fm/$ID"
commit_in "$WT" delivered 'delivered' 'local delivery'
commit_in "$PROJ" sibling 'sibling' 'sibling landed first'
git -C "$PROJ" "${GIT_ID[@]}" cherry-pick "$(git -C "$WT" rev-parse HEAD)" >/dev/null
git -C "$PROJ" merge-base --is-ancestor "$(git -C "$WT" rev-parse HEAD)" "$MAIN" && fail 'fixture kept ancestry'
commit_in "$WT" unique 'unique' 'unique work'
if out=$(teardown 2>&1); then fail 'local-only teardown discarded a commit with no equivalent patch'; fi
retained || fail 'unique-commit refusal lost the copy'
git -C "$WT" reset -q --hard HEAD~1
out=$(teardown 2>&1)
expect_code 0 "$?" "patch-equivalent local-only delivery was not retired: $out"
retired || fail 'patch-equivalent retirement left resources'
git -C "$PROJ" show-ref --verify --quiet "refs/heads/fm/$ID" || fail 'retirement deleted the task branch'
pass 'local-only delivery landed as an identical patch retires, while a commit with no equivalent still refuses'

make_case merge-resolution ship local-only
git -C "$WT" switch -qc "fm/$ID"
commit_in "$WT" conflict left left
left=$(git -C "$WT" rev-parse HEAD)
git -C "$PROJ" switch -qc right "$BASE"
commit_in "$PROJ" conflict right right
if git -C "$WT" "${GIT_ID[@]}" merge right >/dev/null 2>&1; then fail 'expected merge conflict'; fi
commit_in "$WT" conflict 'unique resolution' resolution
git -C "$PROJ" switch -q "$MAIN"
commit_in "$PROJ" advance advance advance
git -C "$PROJ" "${GIT_ID[@]}" cherry-pick "$left" >/dev/null
git -C "$PROJ" "${GIT_ID[@]}" merge -s ours --no-edit right >/dev/null
cherry=$(git -C "$WT" cherry "$MAIN" HEAD)
if [ -z "$cherry" ] || printf '%s\n' "$cherry" | grep -qv '^- '; then fail 'merge fixture lacks equivalent ordinary patches'; fi
if out=$(teardown 2>&1); then fail 'native teardown lost unlanded merge resolution'; fi
assert_contains "$out" 'task delivery is not proven landed' 'native merge refusal reason'
retained || fail 'merge refusal lost native resources'
cp "$HOME_DIR/state/$ID.meta" "$CASE/native.meta"
sed 's/^allocator=git$/allocator=treehouse/' "$CASE/native.meta" > "$HOME_DIR/state/$ID.meta"
mv "$HOME_DIR/state/$ID.git-worktree" "$CASE/reservation"
if out=$(teardown 2>&1); then fail 'legacy teardown lost unlanded merge resolution'; fi
assert_contains "$out" 'work not yet merged into local' 'legacy merge refusal reason'
[ -d "$WT" ] && [ -f "$HOME_DIR/state/$ID.meta" ] || fail 'legacy merge refusal lost resources'
mv "$CASE/native.meta" "$HOME_DIR/state/$ID.meta"
mv "$CASE/reservation" "$HOME_DIR/state/$ID.git-worktree"
git -C "$PROJ" "${GIT_ID[@]}" merge -s ours --no-edit "fm/$ID" >/dev/null
out=$(teardown 2>&1)
expect_code 0 "$?" "ancestral merge was not retired: $out"
retired || fail 'ancestral merge retirement left resources'
pass 'native and legacy teardown reject unlanded merge resolutions and accept ancestral merges'

# C: unlanded commits kept by the recorded branch ref (operating-adoption shape).
make_case retain ship local-only
automatic_backlog
git -C "$WT" switch -qc "fm/$ID"
commit_in "$WT" kept 'kept' 'kept on branch'
head=$(git -C "$WT" rev-parse HEAD)
if out=$(teardown 2>&1); then fail 'unlanded local-only work retired without retention'; fi
retained || fail 'unlanded refusal lost the copy'
if teardown --retain-branch --force >/dev/null 2>&1; then fail '--retain-branch combined with --force'; fi
git -C "$WT" checkout -q --detach
commit_in "$WT" beyond 'beyond' 'beyond the branch'
if out=$(teardown --retain-branch 2>&1); then fail 'retention accepted commits beyond the recorded branch'; fi
retained || fail 'beyond-branch refusal lost the copy'
git -C "$PROJ" show-ref --verify --quiet "refs/firstmate/retained-work/$ID" && fail 'refusal pinned retained work'
git -C "$WT" checkout -q "fm/$ID"
printf 'dirt\n' >> "$WT/kept"
if teardown --retain-branch >/dev/null 2>&1; then fail 'retention discarded uncommitted changes'; fi
git -C "$WT" checkout -q -- kept
out=$(teardown --retain-branch 2>&1)
expect_code 0 "$?" "branch-kept copy was not retired: $out"
retired || fail 'branch retention left resources'
[ "$(git -C "$PROJ" rev-parse "refs/heads/fm/$ID")" = "$head" ] || fail 'retention moved or deleted the branch'
[ "$(git -C "$PROJ" rev-parse "refs/firstmate/retained-work/$ID")" = "$head" ] || fail 'retained work was not pinned'
[ "$(git -C "$PROJ" rev-parse "refs/heads/$MAIN")" = "$BASE" ] || fail 'retention landed the work on main'
assert_closed_note "copy retired unlanded; commits retained on refs/heads/fm/$ID and refs/firstmate/retained-work/$ID at $head"
pass 'branch-kept commits retire only by explicit retention, with the branch kept and the commit pinned'

# An approved local landing still works after retention removed the task record.
merge_local() {
  env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" bash "$ROOT/bin/fm-merge-local.sh" "$ID"
}
printf 'dirt\n' > "$PROJ/dirt"
if out=$(merge_local 2>&1); then fail 'retained-branch landing ignored a dirty main checkout'; fi
assert_contains "$out" 'dirty working tree' 'retained-branch landing lost the clean-main guard'
rm -f -- "$PROJ/dirt"
out=$(merge_local 2>&1)
expect_code 0 "$?" "retained branch could not be landed locally: $out"
[ "$(git -C "$PROJ" rev-parse "refs/heads/$MAIN")" = "$head" ] || fail 'retained-branch landing did not fast-forward main'
[ ! -e "$HOME_DIR/state/$ID.retained" ] || fail 'landing left the retained-branch record behind'
if out=$(merge_local 2>&1); then fail 'a landed retained branch merged twice'; fi
assert_contains "$out" 'no meta for task' 'repeat landing lost its missing-record refusal'
pass 'an approved local landing fast-forwards a retained branch after its task record is gone'

# Rebased and reworded merged PR (audit: edf28acf submitted, PR #13 head
# 4934c119 after rebase and document rounds rewrote the same lines).
make_pipeline_case() {
  make_case "$1" ship no-mistakes
  printf 'pr=https://github.com/fixture/project/pull/7\n' >> "$HOME_DIR/state/$ID.meta"
  git -C "$WT" switch -qc "fm/$ID"
  commit_in "$WT" doc 'original wording' 'original submission'
  submitted=$(git -C "$WT" rev-parse HEAD)
  git -C "$PROJ" switch -qc published "$BASE"
  commit_in "$PROJ" advance 'base advance' 'advance'
  commit_in "$PROJ" doc 'reworded by the pipeline' 'rebased and documented'
  pr_head=$(git -C "$PROJ" rev-parse HEAD)
  git -C "$PROJ" switch -q "$MAIN"
}
make_pipeline_case pipeline
write_sync() { # <submitted> <pushed> <clean> <pr-state>
  cat > "$CASE/sync" <<EOF
branch_sync:
  state: merged_remote_retained
  local:
    branch: fm/$ID
    head: $submitted
    clean: $3
  pipeline:
    run: "01RUN"
    status: completed
    submitted_head: $1
    current_head: $2
    pushed_head: $2
  remote:
    observed_head: $2
  safety: blocked_merged
  pr_state: $4
EOF
}
pipeline_teardown() { FM_TEST_PR_HEAD=$pr_head FM_TEST_SYNC_FILE="$CASE/sync" teardown "$@"; }
for fault in no-binding other-submission other-push unmerged open-pr; do
  write_sync "$submitted" "$pr_head" true merged
  rm_sync=0 state=MERGED
  case "$fault" in
    no-binding) rm_sync=1 ;;
    other-submission) write_sync "$BASE" "$pr_head" true merged ;;
    other-push) write_sync "$submitted" "$BASE" true merged ;;
    unmerged) write_sync "$submitted" "$pr_head" true open ;;
    open-pr) state=OPEN ;;
  esac
  [ "$rm_sync" = 0 ] || rm "$CASE/sync"
  if out=$(FM_TEST_PR_STATE=$state pipeline_teardown 2>&1); then fail "pipeline proof accepted $fault"; fi
  retained || fail "$fault refusal lost the copy"
done
write_sync "$submitted" "$pr_head" true merged
commit_in "$WT" later 'after submission' 'local work after submission'
if out=$(pipeline_teardown 2>&1); then fail 'pipeline proof accepted work committed after submission'; fi
retained || fail 'post-submission refusal lost the copy'
git -C "$WT" reset -q --hard "$submitted"
out=$(pipeline_teardown 2>&1)
expect_code 0 "$?" "pipeline-bound merged PR was not retired: $out"
retired || fail 'pipeline-bound retirement left resources'
pass 'a merged PR rewritten by its pipeline retires only when the pipeline binds this exact clean HEAD to the merged head'

make_pipeline_case pipeline-preserve
write_sync "$submitted" "$pr_head" false merged
mkdir -p "$WT/build" "$WT/.cache"
printf 'generated output\n' > "$WT/build/output"
printf 'ignored cache\n' > "$WT/.cache/cache"
printf '.cache/\n' >> "$PROJ/.git/info/exclude"
keep="$HOME_DIR/data/$ID/preserved-artifacts"
leftovers_untouched() {
  retained && [ "$(cat "$WT/build/output")" = 'generated output' ] \
    && [ "$(cat "$WT/.cache/cache")" = 'ignored cache' ] && [ ! -e "$keep" ]
}
if out=$(pipeline_teardown 2>&1); then fail 'plain pipeline teardown discarded leftovers'; fi
leftovers_untouched || fail 'plain teardown changed leftovers'
if out=$(pipeline_teardown --preserve-untracked build 2>&1); then fail 'pipeline preservation accepted unnamed ignored content'; fi
assert_contains "$out" 'not named' 'coverage refusal did not reach the preservation gate'
leftovers_untouched || fail 'incomplete preservation coverage moved artifacts'
for staged in no yes; do
  printf 'unique tracked edit\n' >> "$WT/doc"
  [ "$staged" = no ] || git -C "$WT" add doc
  if out=$(pipeline_teardown --preserve-untracked build --preserve-untracked .cache 2>&1); then
    fail "pipeline preservation discarded tracked edits (staged=$staged)"
  fi
  assert_contains "$out" 'tracked changes are unique work' 'tracked-edit refusal reason'
  leftovers_untouched || fail 'tracked-edit refusal moved artifacts'
  git -C "$WT" reset -q --hard "$submitted"
done
for fault in submission pushed-head; do
  if [ "$fault" = submission ]; then write_sync "$BASE" "$pr_head" false merged
  else write_sync "$submitted" "$BASE" false merged
  fi
  if out=$(pipeline_teardown --preserve-untracked build --preserve-untracked .cache 2>&1); then
    fail "preservation accepted a mismatched pipeline $fault"
  fi
  leftovers_untouched || fail 'binding refusal moved artifacts'
done
write_sync "$submitted" "$pr_head" false merged
commit_in "$WT" later 'after submission' 'local work after submission'
if out=$(pipeline_teardown --preserve-untracked build --preserve-untracked .cache 2>&1); then
  fail 'preservation accepted work committed after submission'
fi
leftovers_untouched || fail 'post-submission refusal moved artifacts'
git -C "$WT" reset -q --hard "$submitted"
out=$(pipeline_teardown --preserve-untracked build --preserve-untracked .cache 2>&1)
expect_code 0 "$?" "pipeline leftovers were not preserved: $out"
retired || fail 'pipeline preservation left the copy or records'
[ "$(cat "$keep/files/build/output")" = 'generated output' ] || fail 'pipeline preservation lost build output'
[ "$(cat "$keep/files/.cache/cache")" = 'ignored cache' ] || fail 'pipeline preservation lost ignored cache'
pass 'pipeline delivery proof permits covered leftovers while tracked edits and incorrect bindings refuse'

# One-pass cleanup: leftovers that are all recognised generated output are
# preserved in the same teardown, while an unrecognised, tracked, or symlinked
# leftover keeps the ordinary refusal with nothing moved.
make_case generated ship local-only
keep="$HOME_DIR/data/$ID/preserved-artifacts"
mkdir -p "$WT/node_modules/pkg" "$WT/__pycache__"
printf 'module\n' > "$WT/node_modules/pkg/index.js"
printf 'bytecode\n' > "$WT/__pycache__/mod.pyc"
printf 'notes\n' > "$WT/notes.txt"
if out=$(teardown 2>&1); then fail 'an unrecognised leftover was preserved automatically'; fi
assert_contains "$out" '--preserve-untracked' 'unrecognised leftovers lost the guarded next action'
retained && [ -f "$WT/notes.txt" ] && [ -f "$WT/node_modules/pkg/index.js" ] && [ ! -e "$keep" ] \
  || fail 'an unrecognised-leftover refusal moved artifacts or removed records'
rm -f -- "$WT/notes.txt"
git -C "$WT" ls-files --error-unmatch README.md >/dev/null || fail 'fixture lost its tracked README.md'
printf 'unique tracked edit\n' >> "$WT/README.md"
if out=$(teardown 2>&1); then fail 'generated leftovers beside a tracked edit were preserved automatically'; fi
assert_contains "$out" 'tracked changes are unique work' 'tracked-edit refusal reason'
[ -f "$WT/node_modules/pkg/index.js" ] && [ ! -e "$keep" ] || fail 'a tracked-edit refusal moved artifacts'
git -C "$WT" checkout -q -- .
mv "$WT/node_modules" "$CASE/real_modules"
ln -s "$CASE/real_modules" "$WT/node_modules"
if out=$(teardown 2>&1); then fail 'a symlinked node_modules was preserved automatically'; fi
retained && [ ! -e "$keep" ] || fail 'a symlink refusal moved artifacts or removed records'
rm -f -- "$WT/node_modules"
mv "$CASE/real_modules" "$WT/node_modules"
# A generic build directory joins the one pass only once the project ignores it.
mkdir -p "$WT/build"
printf 'object\n' > "$WT/build/app.o"
if out=$(teardown 2>&1); then fail 'an unignored build directory was preserved automatically'; fi
retained && [ ! -e "$keep" ] || fail 'an unignored-build refusal moved artifacts or removed records'
exclude=$(git -C "$WT" rev-parse --path-format=absolute --git-path info/exclude)
mkdir -p -- "${exclude%/*}"
printf '/build/\n' >> "$exclude"
out=$(teardown 2>&1)
expect_code 0 "$?" "recognised generated leftovers were not preserved in one pass: $out"
assert_contains "$out" 'preserving recognised generated output' 'one-pass preservation was not announced'
retired || fail 'one-pass preservation left the copy or records'
[ "$(cat "$keep/files/node_modules/pkg/index.js")" = 'module' ] || fail 'one-pass preservation lost node_modules'
[ "$(cat "$keep/files/__pycache__/mod.pyc")" = 'bytecode' ] || fail 'one-pass preservation lost __pycache__'
[ "$(cat "$keep/files/build/app.o")" = 'object' ] || fail 'one-pass preservation lost project-ignored build output'
pass 'teardown preserves recognised generated output in one pass and still refuses unrecognised, tracked, or symlinked leftovers'

for scenario in clean partial explicit; do
  make_case "generated-retry-$scenario" ship local-only
  keep="$HOME_DIR/data/$ID/preserved-artifacts"
  mkdir -p "$WT/__pycache__"
  printf 'bytecode\n' > "$WT/__pycache__/mod.pyc"
  expected_receipts='__pycache__ '
  if [ "$scenario" != clean ]; then
    mkdir -p "$WT/node_modules/pkg"
    printf 'module\n' > "$WT/node_modules/pkg/index.js"
    expected_receipts='__pycache__ node_modules '
  fi
  real_mv=$(command -v mv)
  cat > "$FAKE/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_FAIL_MV_TARGET:-}" ]; then printf 'fixture interruption\n' >&2; exit 1; fi
done
exec "${FM_TEST_REAL_MV:?}" "$@"
SH
  chmod +x "$FAKE/mv"
  if out=$(FM_TEST_REAL_MV="$real_mv" FM_TEST_FAIL_MV_TARGET="$keep/receipt" teardown 2>&1); then
    fail "$scenario automatic preservation ignored a receipt interruption"
  fi
  "$real_mv" "$FAKE/mv" "$CASE/mv-shim"
  assert_contains "$out" 'fixture interruption' 'fixture did not interrupt receipt publication'
  retained && [ ! -e "$WT/__pycache__" ] && [ -f "$keep/files/__pycache__/mod.pyc" ] \
    && [ ! -e "$keep/receipt" ] || fail "$scenario interruption lost custody or retired records"
  if [ "$scenario" = clean ]; then
    [ -z "$(git -C "$WT" ls-files --others)" ] || fail 'clean retry still has leftovers'
  else
    [ -f "$WT/node_modules/pkg/index.js" ] || fail 'interruption moved past its failed receipt'
  fi
  retry_args=()
  [ "$scenario" != explicit ] || retry_args=(--preserve-untracked node_modules)
  printf 'corrupted\n' > "$keep/files/__pycache__/mod.pyc"
  if out=$(teardown "${retry_args[@]+"${retry_args[@]}"}" 2>&1); then
    fail "$scenario retry retired an unverified journaled artifact"
  fi
  assert_contains "$out" 'does not match its journaled manifest' 'retry skipped custody verification'
  retained && [ ! -e "$keep/receipt" ] || fail 'manifest refusal retired records or published a receipt'
  printf 'bytecode\n' > "$keep/files/__pycache__/mod.pyc"
  if [ "$scenario" = clean ]; then
    printf 'unique tracked edit\n' >> "$WT/README.md"
    if out=$(teardown 2>&1); then fail 'journal recovery discarded tracked edits'; fi
    retained && [ ! -e "$keep/receipt" ] || fail 'tracked-edit refusal lost records or receipted artifacts'
    git -C "$WT" checkout -q -- README.md
    printf 'unique notes\n' > "$WT/notes.txt"
    if out=$(teardown 2>&1); then fail 'journal recovery accepted uncertain leftovers'; fi
    retained && [ -f "$WT/notes.txt" ] && [ ! -e "$keep/receipt" ] || fail 'uncertain-leftover refusal lost work'
    rm -- "$WT/notes.txt"
    commit_in "$WT" unique 'unlanded work' 'unlanded work'
    if out=$(teardown 2>&1); then fail 'journal recovery retired unlanded work'; fi
    retained && [ ! -e "$keep/receipt" ] || fail 'unlanded refusal lost records or receipted artifacts'
    git -C "$WT" reset -q --hard "$BASE"
  fi
  out=$(teardown "${retry_args[@]+"${retry_args[@]}"}" 2>&1)
  expect_code 0 "$?" "$scenario automatic preservation did not resume: $out"
  retired || fail "$scenario preservation retry left the copy or records"
  [ "$(cat "$keep/files/__pycache__/mod.pyc")" = bytecode ] || fail 'retry lost the already-moved artifact'
  if [ "$scenario" != clean ]; then
    [ "$(cat "$keep/files/node_modules/pkg/index.js")" = module ] || fail 'retry lost the remaining artifact'
  fi
  [ "$(cut -f3 "$keep/receipt" | sort | tr '\n' ' ')" = "$expected_receipts" ] \
    || fail "$scenario retry did not receipt each artifact exactly once"
  pass "$scenario preservation retry verifies moved artifacts before retiring and receipts every path once"
done

# One-pass stop: a native task whose status reads done is stopped through task
# control before the endpoint gate; an unfinished task is never stopped, and a
# failed stop keeps the refusal and names the failure.
stop_case() { # <name> <status-line>
  make_case "$1" ship local-only
  rm -rf -- "${CASE:?}/root"
  mkdir -p "$CASE/root"
  cp -R "$ROOT/bin" "$CASE/root/bin"
  cat > "$CASE/root/bin/fm-control.sh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$*" >> "$FM_TEST_CASE/control.log"
if [ "${FM_TEST_CONTROL_FAIL:-0}" = 1 ]; then echo 'error: stub control refused' >&2; exit 1; fi
: > "$FM_TEST_CASE/stopped"
echo 'stopped'
SH
  chmod +x "$CASE/root/bin/fm-control.sh"
  cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'main\n'; [ -f "$FM_TEST_CASE/stopped" ] || printf 'fm-%s\n' "$FM_TEST_ID" ;;
  *) exit 1 ;;
esac
SH
  chmod +x "$FAKE/tmux"
  printf '%s\n' "$2" > "$HOME_DIR/state/$ID.status"
}
stop_teardown() {
  env PATH="$FAKE:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 \
    FM_TEST_CASE="$CASE" FM_TEST_ID="$ID" \
    bash "$CASE/root/bin/fm-teardown.sh" "$ID" "$@"
}
stop_case stop-working 'working [at=1792922400]: still implementing'
if out=$(stop_teardown 2>&1); then fail 'teardown retired a live endpoint of an unfinished task'; fi
assert_contains "$out" 'live or unverified endpoint owner' 'unfinished-task refusal reason'
[ ! -e "$CASE/control.log" ] || fail 'teardown stopped an unfinished worker'
retained || fail 'unfinished-task refusal lost the copy'
stop_case stop-failed 'done [at=1792922400]: ready in branch fm/x'
if out=$(FM_TEST_CONTROL_FAIL=1 stop_teardown 2>&1); then fail 'teardown retired a live endpoint after a failed stop'; fi
assert_contains "$out" 'stub control refused' 'a failed stop was not named in the refusal'
retained || fail 'failed-stop refusal lost the copy'
if out=$(stop_teardown --force 2>&1); then :; fi
[ "$(wc -l < "$CASE/control.log")" = 1 ] || fail 'a forced teardown stopped the worker through task control'
stop_case stop-done 'done [at=1792922400]: ready in branch fm/x'
out=$(stop_teardown 2>&1)
expect_code 0 "$?" "a finished task's live worker was not stopped and retired in one pass: $out"
[ "$(cat "$CASE/control.log")" = "$ID exit" ] || fail 'teardown did not stop the finished worker exactly once through task control'
retired || fail 'one-pass stop left the copy or records'
pass 'teardown stops a finished native worker through task control in one pass and never stops an unfinished one'

test_stop_marked_lab() (
  # Exercise the real control entrypoint with its gate guard enabled. Only the
  # terminal transport is modelled; no lifecycle or authorization code is stubbed.
  local var out keep
  for var in "${!FM_@}"; do
    case "$var" in *_OVERRIDE) unset "$var" ;; esac
  done
  unset FM_GATE_REFUSE_BYPASS
  export NO_MISTAKES_GATE=1
  bash "$ROOT/bin/fm-lab-home.sh" create "$TMP_ROOT/stop-lab/home" >/dev/null || fail 'lab creation failed'
  make_case stop-lab ship local-only
  printf 'harness=codex\n' >> "$HOME_DIR/state/$ID.meta"
  mkdir -p "$WT/node_modules/pkg"
  printf 'module\n' > "$WT/node_modules/pkg/index.js"
  cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    printf 'main\n'
    [ -f "$FM_TEST_CASE/closed" ] || printf 'fm-%s\n' "$FM_TEST_ID" ;;
  display-message)
    case "${*: -1}" in
      *pane_current_command*)
        if [ -f "$FM_TEST_CASE/stopped" ]; then printf 'bash\n'; else printf 'codex\n'; fi ;;
      *pane_current_path*) printf '%s\n' "$FM_TEST_WORKTREE" ;;
      *pane_pid*) printf '%s\n' "$$" ;;
      *cursor_y*) printf '1\n' ;;
      *) exit 1 ;;
    esac ;;
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  send-keys)
    if [ "${*: -1}" = /quit ]; then
      printf '/quit\n' >> "$FM_TEST_CASE/control.log"
      touch "$FM_TEST_CASE/stopped"
    fi ;;
  kill-window) touch "$FM_TEST_CASE/closed" ;;
  *) exit 1 ;;
esac
SH
  export FM_HOME="$HOME_DIR" FM_TEST_CASE="$CASE" FM_TEST_ID="$ID" FM_TEST_WORKTREE="$WT"
  export PATH="$FAKE:$PATH"
  printf 'working [at=1792922400]: still implementing\n' > "$HOME_DIR/state/$ID.status"
  if out=$(bash "$ROOT/bin/fm-teardown.sh" "$ID" 2>&1); then fail 'lab teardown stopped unfinished work'; fi
  assert_contains "$out" 'live or unverified endpoint owner' 'lab unfinished-task refusal reason'
  if ! { [ ! -e "$CASE/control.log" ] && [ -f "$WT/node_modules/pkg/index.js" ] && retained; }; then
    fail 'lab unfinished-task refusal changed worker or copy'
  fi
  printf 'done [at=1792922400]: ready in branch fm/x\n' > "$HOME_DIR/state/$ID.status"
  out=$(FM_STATE_OVERRIDE="$HOME_DIR/state" bash "$ROOT/bin/fm-teardown.sh" "$ID" 2>&1)
  expect_code 3 "$?" 'lab teardown with a caller override must retain the gate refusal'
  if ! { [ ! -e "$CASE/control.log" ] && retained; }; then
    fail 'caller override was dropped before task control'
  fi
  out=$(bash "$ROOT/bin/fm-teardown.sh" "$ID" 2>&1)
  expect_code 0 "$?" "marked lab did not stop, preserve and retire in one pass: $out"
  [ "$(cat "$CASE/control.log")" = /quit ] || fail 'lab worker was not stopped exactly once'
  keep="$HOME_DIR/data/$ID/preserved-artifacts"
  [ "$(cat "$keep/files/node_modules/pkg/index.js")" = module ] && [ -s "$keep/receipt" ] \
    || fail 'lab one-pass stop lost generated output or its receipt'
  retired || fail 'lab one-pass stop left the copy or records'
  pass 'marked stock-layout lab stops only finished workers and preserves generated output in one pass'
)
test_stop_marked_lab || exit 1

SHELL_PIDS=()
SHELL_SUPERVISORS=()
cleanup_shells() {
  for pid in "${SHELL_PIDS[@]+"${SHELL_PIDS[@]}"}"; do kill "$pid" 2>/dev/null || true; done
  for pid in "${SHELL_SUPERVISORS[@]+"${SHELL_SUPERVISORS[@]}"}"; do wait "$pid" 2>/dev/null || true; done
  fm_test_cleanup
}
trap cleanup_shells EXIT
start_shell() {
  local label=$1 attempt
  mkfifo "$CASE/$label.fifo"
  python3 - "$WT" "$CASE/$label" <<'PYTHON' &
import pathlib, subprocess, sys
prefix = pathlib.Path(sys.argv[2])
process = subprocess.Popen(["bash", "-c", 'read -r _ < "$1"', "_", str(prefix) + ".fifo"],
                           cwd=sys.argv[1], start_new_session=True,
                           stdin=subprocess.DEVNULL, stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
prefix.with_suffix(".pid").write_text(str(process.pid))
process.wait()
PYTHON
  SHELL_SUPERVISORS+=("$!")
  for ((attempt=0; attempt<100; attempt++)); do
    [ ! -s "$CASE/$label.pid" ] || break
    sleep 0.01
  done
  SHELL_PID=$(cat "$CASE/$label.pid") || fail 'shell fixture did not start'
  SHELL_PIDS+=("$SHELL_PID")
  lsof -a -p "$SHELL_PID" -d cwd -Fn | grep -Fx "n$WT" >/dev/null || fail 'fixture shell does not hold the copy cwd'
}

for scenario in herdr-success herdr-failed herdr-unconfirmed herdr-foreign tmux-success; do
  make_case "$scenario" ship local-only
  backend=${scenario%%-*}
  start_shell endpoint
  endpoint_pid=$SHELL_PID
  mkdir -p "$WT/build"
  printf 'generated bytes\n' > "$WT/build/output"
  fm_write_meta "$HOME_DIR/state/$ID.meta" \
    "window=native-fixture:w1:p1" "endpoint_task_id=$ID" "backend=$backend" \
    "worktree=$WT" "project=$PROJ" 'kind=ship' 'mode=local-only' \
    'spawn_gen=s1792922400.123.456' 'allocator=git'
  if [ "$backend" = tmux ]; then
    sed "s/window=native-fixture:w1:p1/window=native-fixture:fm-$ID/" "$HOME_DIR/state/$ID.meta" > "$CASE/meta"
    mv "$CASE/meta" "$HOME_DIR/state/$ID.meta"
  else
    printf '%s\n' 'herdr_session=native-fixture' 'herdr_workspace_id=w1' \
      'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' >> "$HOME_DIR/state/$ID.meta"
  fi
  cat > "$FAKE/close-endpoint" <<'SH'
#!/usr/bin/env bash
case "${FM_TEST_CLOSE_FAIL:-}" in failed) exit 1 ;; unconfirmed) exit 0 ;; esac
[ ! -f "$FM_TEST_CASE/closed" ] || exit 0
pid=$(cat "$FM_TEST_CASE/endpoint.pid")
kill "$pid" || exit 1
for ((attempt=0; attempt<100; attempt++)); do
  if ! kill -0 "$pid" 2>/dev/null; then
    touch "$FM_TEST_CASE/closed"
    exit 0
  fi
  sleep 0.01
done
exit 1
SH
  cat > "$FAKE/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pane get')
    if [ -f "$FM_TEST_CASE/closed" ]; then
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'; exit 1
    fi
    printf '%s\n' '{"result":{"pane":{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1"}}}' ;;
  'agent get') printf '%s\n' '{"error":{"code":"agent_not_found"}}'; exit 1 ;;
  'pane process-info')
    pid=$(cat "$FM_TEST_CASE/endpoint.pid")
    printf '{"result":{"type":"pane_process_info","process_info":{"pane_id":"w1:p1","shell_pid":%s,"foreground_process_group_id":%s,"foreground_processes":[{"pid":%s,"name":"bash","argv0":"bash"}]}}}\n' "$pid" "$pid" "$pid" ;;
  'pane close') exec close-endpoint ;;
  'session list') printf '{"sessions":[{"name":"native-fixture","running":true,"socket_path":"%s/herdr.sock"}]}\n' "$FM_TEST_CASE" ;;
  'status --json') printf '%s\n' '{"server":{"running":true}}' ;;
  'workspace list') printf '%s\n' '{"result":{"workspaces":[]}}' ;;
esac
SH
  cat > "$FAKE/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows) printf 'main\n'; [ -f "$FM_TEST_CASE/closed" ] || printf 'fm-retire-%s\n' "${FM_TEST_CASE##*/}" ;;
  display-message)
    case "${*: -1}" in
      '#{pane_pid}') cat "$FM_TEST_CASE/endpoint.pid" ;;
      '#{pane_current_command}') printf 'bash\n' ;;
      *) exit 1 ;;
    esac ;;
  kill-window) exec close-endpoint ;;
esac
SH
  chmod +x "$FAKE/herdr" "$FAKE/tmux" "$FAKE/close-endpoint"
  preserve_teardown() { FM_TEST_CASE="$CASE" teardown --preserve-untracked build; }
  if out=$(FM_TEST_CASE="$CASE" teardown 2>&1); then fail 'plain teardown discarded generated leftovers'; fi
  if [ -e "$CASE/closed" ] || ! kill -0 "$endpoint_pid"; then fail 'plain refusal closed the endpoint'; fi
  case "$scenario" in
    herdr-failed|herdr-unconfirmed)
      if out=$(FM_TEST_CLOSE_FAIL="${scenario#herdr-}" preserve_teardown 2>&1); then fail 'unproven close allowed preservation'; fi
      assert_contains "$out" 'not confirmed gone' 'endpoint-close refusal reason'
      retained && [ -f "$WT/build/output" ] && [ ! -e "$HOME_DIR/data/$ID/preserved-artifacts" ] || fail 'close refusal moved artifacts or removed records'
      kill -0 "$endpoint_pid" || fail 'failed-close fixture lost its endpoint shell' ;;
    herdr-foreign)
      start_shell foreign
      foreign_pid=$SHELL_PID
      if out=$(preserve_teardown 2>&1); then fail 'foreign copy process allowed preservation'; fi
      assert_contains "$out" 'native copy still has processes; nothing preserved' 'foreign-process refusal reason'
      [ -f "$CASE/closed" ] || fail 'recorded endpoint was not closed before process inspection'
      retained && [ -f "$WT/build/output" ] && [ ! -e "$HOME_DIR/data/$ID/preserved-artifacts" ] || fail 'foreign-process refusal moved artifacts or removed records'
      kill -0 "$foreign_pid" || fail 'teardown killed a foreign process'
      kill "$foreign_pid"
      wait "${SHELL_SUPERVISORS[${#SHELL_SUPERVISORS[@]}-1]}" || fail 'foreign shell supervisor failed' ;;
  esac
  out=$(preserve_teardown 2>&1)
  expect_code 0 "$?" "$scenario could not preserve after closing endpoint: $out"
  retired || fail "$scenario left the copy or task records"
  [ -f "$CASE/closed" ] || fail "$scenario did not close the endpoint"
  [ "$(cat "$HOME_DIR/data/$ID/preserved-artifacts/files/build/output")" = 'generated bytes' ] || fail "$scenario lost generated artifacts"
  pass "$scenario closes the recorded shell before preserving and retiring the native copy"
done

cleanup_shells
