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

# C: unlanded commits kept by the recorded branch ref (operating-adoption shape).
make_case retain ship local-only
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
pass 'branch-kept commits retire only by explicit retention, with the branch kept and the commit pinned'

# Rebased and reworded merged PR (audit: edf28acf submitted, PR #13 head
# 4934c119 after rebase and document rounds rewrote the same lines).
make_case pipeline ship no-mistakes
printf 'pr=https://github.com/fixture/project/pull/7\n' >> "$HOME_DIR/state/$ID.meta"
git -C "$WT" switch -qc "fm/$ID"
commit_in "$WT" doc 'original wording' 'original submission'
submitted=$(git -C "$WT" rev-parse HEAD)
git -C "$PROJ" switch -qc published "$BASE"
commit_in "$PROJ" advance 'base advance' 'advance'
commit_in "$PROJ" doc 'reworded by the pipeline' 'rebased and documented'
pr_head=$(git -C "$PROJ" rev-parse HEAD)
git -C "$PROJ" switch -q "$MAIN"
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
pipeline_teardown() { FM_TEST_PR_HEAD=$pr_head FM_TEST_SYNC_FILE="$CASE/sync" teardown; }
for fault in no-binding other-submission other-push unmerged dirty-claim open-pr; do
  write_sync "$submitted" "$pr_head" true merged
  rm_sync=0 state=MERGED
  case "$fault" in
    no-binding) rm_sync=1 ;;
    other-submission) write_sync "$BASE" "$pr_head" true merged ;;
    other-push) write_sync "$submitted" "$BASE" true merged ;;
    unmerged) write_sync "$submitted" "$pr_head" true open ;;
    dirty-claim) write_sync "$submitted" "$pr_head" false merged ;;
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

fm_test_cleanup
