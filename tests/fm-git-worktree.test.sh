#!/usr/bin/env bash
# Native allocation/reservation/source and conservative removal regressions.
set -u
# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"
# shellcheck source=bin/fm-git-worktree-lib.sh disable=SC1091
. "$ROOT/bin/fm-git-worktree-lib.sh"
TMP_ROOT=$(fm_test_tmproot fm-git-worktree)

make_case() {
  CASE="$TMP_ROOT/$1"
  HOME_DIR="$CASE/home"
  PROJ="$CASE/project"
  COPY_ROOT="$CASE/copies"
  fm_test_spawn_home "$HOME_DIR" codex
  fm_git_init_commit "$PROJ"
  BASE=$(git -C "$PROJ" rev-parse HEAD)
  MAIN=$(git -C "$PROJ" symbolic-ref --short HEAD)
  printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
  printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
  printf -- '- project [local-only]\n' > "$HOME_DIR/data/projects.md"
}

allocate() {
  fm_git_worktree_allocate "$HOME_DIR/state" "$1" "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$BASE" "refs/heads/$MAIN"
}
remove_copy() {
  fm_git_worktree_remove "$HOME_DIR/state" "$1" "$HOME_DIR" "$PROJ" "$COPY_ROOT/$1/worktree"
}

make_case resume
allocate resumed || fail 'initial native allocation failed'
WT=$FM_GIT_WORKTREE_PATH
git -C "$PROJ" worktree list --porcelain > "$CASE/before"
# Repeating after a caller interruption reuses the reservation/copy, not add.
allocate resumed || fail 'interrupted allocation did not resume'
git -C "$PROJ" worktree list --porcelain > "$CASE/after"
cmp "$CASE/before" "$CASE/after" || fail 'recovery created another copy'
[ "$WT" = "$FM_GIT_WORKTREE_PATH" ] || fail 'recovery changed identity'
printf 'worktree=%s\n' "$WT" > "$CASE/inconsistent.meta"
if fm_git_worktree_meta_allocator "$CASE/inconsistent.meta" "$HOME_DIR/state/resumed.git-worktree"; then
  fail 'missing allocator could route native copy through pooled cleanup'
fi
printf 'allocator=git\nallocator=treehouse\n' > "$CASE/inconsistent.meta"
if fm_git_worktree_meta_allocator "$CASE/inconsistent.meta" "$HOME_DIR/state/resumed.git-worktree"; then
  fail 'ambiguous allocator metadata was accepted'
fi
alternate=$(printf 'different source\n' | git -C "$PROJ" -c user.name='Firstmate Tests' \
  -c user.email=tests@example.invalid commit-tree "$BASE^{tree}" -p "$BASE")
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$alternate" "refs/heads/$MAIN"; then
  fail 'recovery silently rebased a reserved source'
fi
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail 'changed-source refusal moved HEAD'
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$alternate"
fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$alternate" "refs/heads/$MAIN" \
  || fail 'fast-forward source advance wedged an unpublished reservation'
[ "$(git -C "$WT" rev-parse HEAD)" = "$BASE" ] || fail 'fast-forward recovery moved the reserved HEAD'
[ "$(fm_git_worktree_field "$HOME_DIR/state/resumed.git-worktree" base)" = "$BASE" ] || fail 'recovery rewrote the reserved base'
[ ! -e "$HOME_DIR/state/resumed.meta" ] || fail 'library recovery published task metadata'
rewritten=$(printf 'unrelated history\n' | git -C "$PROJ" -c user.name='Firstmate Tests' \
  -c user.email=tests@example.invalid commit-tree "$BASE^{tree}")
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$rewritten"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$rewritten" "refs/heads/$MAIN"; then
  fail 'rewritten source history adopted reservation'
fi
git -C "$PROJ" update-ref "refs/heads/$MAIN" "$BASE"
git -C "$PROJ" branch alternate-source "$BASE"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$BASE" refs/heads/alternate-source; then
  fail 'different source ref adopted reservation'
fi
mkdir "$CASE/other-copies"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$PROJ" "$CASE/other-copies" "$BASE" "refs/heads/$MAIN"; then
  fail 'changed root adopted reservation'
fi
fm_git_init_commit "$CASE/other-project"
other_base=$(git -C "$CASE/other-project" rev-parse HEAD)
other_main=$(git -C "$CASE/other-project" symbolic-ref --short HEAD)
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$HOME_DIR" "$CASE/other-project" "$COPY_ROOT" "$other_base" "refs/heads/$other_main"; then
  fail 'foreign project adopted reservation'
fi
printf 'worktree=%s\n' "$WT" > "$HOME_DIR/state/resumed.meta"
if allocate resumed; then fail 'published reservation was reused by a fresh allocation'; fi
rm "$HOME_DIR/state/resumed.meta"
mkdir "$CASE/foreign-home"
if fm_git_worktree_allocate "$HOME_DIR/state" resumed "$CASE/foreign-home" "$PROJ" "$COPY_ROOT" "$BASE" "refs/heads/$MAIN"; then
  fail 'foreign home adopted reservation'
fi
remove_copy resumed || fail 'clean accepted copy did not remove'
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/resumed.git-worktree" ] || fail 'cleanup retained live reservation'
pass 'native reservation resumes one copy, rejects foreign ownership and removes clean accepted copy'

for stage in reservation container empty partial; do
  make_case "interrupt-$stage"
  mkdir() {
    if [ "$stage" = reservation ] && [ "${*: -1}" = "$COPY_ROOT/interrupted" ]; then return 1; fi
    command mkdir "$@"
  }
  git() {
    if [ "${3:-} ${4:-}" = 'worktree add' ]; then
      case "$stage" in
        container) return 1 ;;
        empty) command mkdir -m 700 "$6"; return 1 ;;
        partial) command git -C "$2" worktree add --detach --no-checkout "$6" "$7"; return 1 ;;
      esac
    fi
    command git "$@"
  }
  if allocate interrupted; then fail "fault $stage did not interrupt creation"; fi
  unset -f mkdir git
  [ -f "$HOME_DIR/state/interrupted.git-worktree" ] || fail "$stage lost reservation"
  [ ! -e "$HOME_DIR/state/interrupted.meta" ] || fail "$stage published metadata"
  if [ "$stage" = reservation ]; then
    [ ! -e "$COPY_ROOT/interrupted" ] || fail 'reservation was published after task directory creation'
  fi
  if [ "$stage" = partial ]; then
    git -C "$COPY_ROOT/interrupted/worktree" status --porcelain > "$CASE/before"
    if allocate interrupted; then fail 'partial checkout was treated as clean'; fi
    git -C "$COPY_ROOT/interrupted/worktree" status --porcelain > "$CASE/after"
    cmp "$CASE/before" "$CASE/after" || fail 'partial checkout refusal changed work'
  else
    allocate interrupted || fail "$stage reservation could not resume"
    [ "$(git -C "$FM_GIT_WORKTREE_PATH" rev-parse HEAD)" = "$BASE" ] || fail "$stage recovery changed base"
    remove_copy interrupted || fail "$stage resumed copy could not be removed"
  fi
  pass "native $stage interruption preserves ownership and resumes only clean creation"
done

make_case branch
allocate branch || fail 'branch fixture allocation failed'
git -C "$FM_GIT_WORKTREE_PATH" switch -qc user-branch
if allocate branch; then fail 'recovery adopted a changed branch at the same base'; fi
[ "$(git -C "$FM_GIT_WORKTREE_PATH" symbolic-ref --short HEAD)" = user-branch ] || fail 'branch refusal changed user branch'
pass 'native recovery preserves a user branch even at the recorded base'

make_case live
allocate live || fail 'live fixture allocation failed'
WT=$FM_GIT_WORKTREE_PATH
bash -c 'cd "$1" && printf ready > "$2" && exec sleep 60' _ "$WT" "$CASE/ready" &
owner=$!
for _ in $(seq 1 100); do [ ! -f "$CASE/ready" ] || break; sleep 0.01; done
if [ ! -f "$CASE/ready" ]; then kill "$owner"; wait "$owner" || true; fail 'live owner did not start'; fi
if allocate live; then kill "$owner"; wait "$owner" || true; fail 'live process owner was ignored'; fi
kill "$owner"
wait "$owner" || true
fakebin=$(fm_fakebin "$CASE/fake")
printf '#!/usr/bin/env bash\nexit 1\n' > "$fakebin/lsof"
chmod +x "$fakebin/lsof"
if PATH="$fakebin:$PATH" allocate live; then fail 'unverifiable process ownership was accepted'; fi
allocate live || fail 'clean reservation could not resume after owner exited'
pass 'native recovery refuses live and unverified owners'

make_case collisions
mkdir -p "$COPY_ROOT/collision"
printf 'preserve\n' > "$COPY_ROOT/collision/sentinel"
if allocate collision; then fail 'existing unrelated task path was overwritten'; fi
[ "$(cat "$COPY_ROOT/collision/sentinel")" = preserve ] || fail 'collision lost bytes'
if fm_git_worktree_allocate "$HOME_DIR/state" nested "$HOME_DIR" "$PROJ" "$PROJ/unsafe" "$BASE" "refs/heads/$MAIN"; then
  fail 'allocator accepted a root inside primary'
fi
[ ! -e "$PROJ/unsafe" ] || fail 'unsafe root preflight wrote inside primary'
pass 'native allocation refuses existing paths and primary roots before writing them'

make_case content
allocate content || fail 'content fixture allocation failed'
WT=$FM_GIT_WORKTREE_PATH
printf 'untracked\n' > "$WT/untracked"
if allocate content; then fail 'untracked copy was resumed'; fi
if remove_copy content; then fail 'untracked content was discarded'; fi
[ "$(cat "$WT/untracked")" = untracked ] || fail 'untracked bytes lost'
rm "$WT/untracked"
printf 'ignored\n' >> "$PROJ/.git/info/exclude"
printf 'private\n' > "$WT/ignored"
if allocate content; then fail 'ignored content was resumed'; fi
if remove_copy content; then fail 'ignored untracked content was discarded'; fi
[ "$(cat "$WT/ignored")" = private ] || fail 'ignored bytes lost'
rm "$WT/ignored"
printf 'tracked edit\n' >> "$WT/README.md"
if allocate content; then fail 'tracked dirt was resumed'; fi
if remove_copy content; then fail 'tracked dirt was discarded'; fi
git -C "$WT" add README.md
git -C "$WT" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit -qm unlanded
git -C "$WT" branch retained-unlanded
if allocate content; then fail 'changed HEAD was resumed'; fi
if remove_copy content; then fail 'unlanded committed work was discarded'; fi
[ -d "$WT" ] && [ -f "$HOME_DIR/state/content.git-worktree" ] || fail 'refusal lost copy/record'
pass 'native cleanup preserves untracked, ignored, dirty and unlanded content'

make_case remote-landing
git clone -q --bare "$PROJ" "$CASE/origin.git"
git -C "$PROJ" remote add origin "file://$CASE/origin.git"
git -C "$CASE/origin.git" branch other "$BASE"
git -C "$PROJ" fetch -q origin
fm_git_worktree_allocate "$HOME_DIR/state" landed "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$BASE" "refs/remotes/origin/$MAIN" \
  || fail 'remote landing fixture allocation failed'
WT=$FM_GIT_WORKTREE_PATH
printf 'merged change\n' > "$WT/merged"
git -C "$WT" add merged
git -C "$WT" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit -qm merged
merged=$(git -C "$WT" rev-parse HEAD)
git -C "$CASE/origin.git" fetch -q "$WT" "HEAD:refs/heads/$MAIN" HEAD:refs/heads/other
[ "$(git -C "$PROJ" rev-parse "refs/remotes/origin/$MAIN")" = "$BASE" ] || fail 'remote landing fixture did not leave a stale tracking ref'
fm_git_worktree_safe "$HOME_DIR/state" landed "$HOME_DIR" "$PROJ" "$WT" || fail 'merged remote source was not refreshed before native ancestry proof'
[ "$(git -C "$PROJ" rev-parse "refs/remotes/origin/$MAIN")" = "$merged" ] || fail 'recorded remote source did not advance'
[ "$(git -C "$PROJ" rev-parse refs/remotes/origin/other)" = "$BASE" ] || fail 'native safety fetched an unrelated remote ref'
git -C "$PROJ" remote set-url origin "$CASE/missing-remote"
if remove_copy landed; then fail 'native removal trusted cached ancestry after a failed fetch'; fi
[ -d "$WT" ] && [ -f "$HOME_DIR/state/landed.git-worktree" ] || fail 'failed remote refresh lost native work'
git -C "$PROJ" remote set-url origin "file://$CASE/origin.git"
remove_copy landed || fail 'native merged remote copy could not retire'
pass 'native safety refreshes only its recorded remote ref and fails closed on refresh failure'

make_case rebased-delivery
allocate rebased || fail 'rebased fixture allocation failed'
WT=$FM_GIT_WORKTREE_PATH
printf 'delivered\n' > "$WT/delivered"
git -C "$WT" add delivered
git -C "$WT" -c user.name=test -c user.email=test@example.invalid commit -qm original
original=$(git -C "$WT" rev-parse HEAD)
printf 'new base\n' > "$PROJ/new-base"
git -C "$PROJ" add new-base
git -C "$PROJ" -c user.name=test -c user.email=test@example.invalid commit -qm advance
git -C "$PROJ" -c user.name=test -c user.email=test@example.invalid cherry-pick "$original" >/dev/null
if remove_copy rebased; then fail 'default native source gate accepted non-ancestral HEAD'; fi
native_delivered() {
  [ "$(git -C "$WT" merge-tree --write-tree "refs/heads/$MAIN" HEAD)" = "$(git -C "$PROJ" rev-parse 'HEAD^{tree}')" ]
}
if fm_git_worktree_safe "$HOME_DIR/state" rebased "$HOME_DIR" "$PROJ" "$WT" missing_proof; then
  fail 'missing landed proof was accepted'
fi
printf 'private evidence\n' > "$WT/private"
if fm_git_worktree_safe "$HOME_DIR/state" rebased "$HOME_DIR" "$PROJ" "$WT" native_delivered; then
  fail 'landed proof bypassed untracked preservation'
fi
rm "$WT/private"
fm_git_worktree_remove "$HOME_DIR/state" rebased "$HOME_DIR" "$PROJ" "$WT" native_delivered \
  || fail 'proved rebased delivery could not be removed'
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/rebased.git-worktree" ] || fail 'rebased cleanup left resources'
pass 'native cleanup accepts an explicit landed-work proof without weakening default ancestry or dirt gates'

for kind in ship scout remote; do
  make_case "source-$kind"
  # Local and origin share a base but then diverge, matching the recurrence.
  git clone -q --bare "$PROJ" "$CASE/origin.git"
  git -C "$PROJ" remote add origin "file://$CASE/origin.git"
  remote=$(printf 'remote divergence\n' | git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit-tree "$BASE^{tree}" -p "$BASE")
  git -C "$PROJ" update-ref refs/heads/remote-fixture "$remote"
  git -C "$CASE/origin.git" fetch -q "$PROJ" "refs/heads/remote-fixture:refs/heads/$MAIN"
  printf 'accepted locally\n' > "$PROJ/local-only"
  git -C "$PROJ" add local-only
  git -C "$PROJ" -c user.name='Firstmate Tests' -c user.email=tests@example.invalid commit -qm local-accepted
  local_head=$(git -C "$PROJ" rev-parse HEAD)
  id="native-$kind-$$"
  FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
  fm_test_spawn_brief "$HOME_DIR" "$id"
  fakebin=$(make_spawn_fakebin "$CASE/fake")
  WT="$COPY_ROOT/$id/worktree"
  args=(--mode local-only --yolo off)
  [ "$kind" != scout ] || args=(--scout)
  [ "$kind" != remote ] || args=(--mode no-mistakes --yolo off)
  if [ "$kind" = remote ]; then
    git -C "$PROJ" fetch -q origin
    fm_git_worktree_allocate "$HOME_DIR/state" "$id" "$HOME_DIR" "$PROJ" "$COPY_ROOT" "$remote" "refs/remotes/origin/$MAIN" \
      || fail 'remote reservation fixture failed'
    advanced=$(printf 'remote advance\n' | git -C "$PROJ" -c user.name='Firstmate Tests' \
      -c user.email=tests@example.invalid commit-tree "$remote^{tree}" -p "$remote")
    git -C "$PROJ" update-ref refs/heads/remote-fixture "$advanced"
    git -C "$CASE/origin.git" fetch -q "$PROJ" "refs/heads/remote-fixture:refs/heads/$MAIN"
  fi
  out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$id" "$PROJ" 'sh -c true' "${args[@]}" 2>&1)
  rc=$?
  expect_code 0 "$rc" "native $kind spawn failed: $out"
  expected=$local_head
  [ "$kind" != remote ] || expected=$remote
  [ "$(git -C "$WT" rev-parse HEAD)" = "$expected" ] || fail "$kind chose the wrong source"
  assert_contains "$out" "base=$expected" 'spawn reported a different base than the actual reserved copy'
  assert_grep 'allocator=git' "$HOME_DIR/state/$id.meta" 'native identity was not recorded'
  if out=$(fm_test_run_spawn "$HOME_DIR" "$WT" "$fakebin" "$id" "$PROJ" 'sh -c true' "${args[@]}" 2>&1); then
    fail 'duplicate task spawn started another worker'
  fi
  [ "$(git -C "$PROJ" worktree list --porcelain | grep -c '^worktree ')" = 2 ] || fail 'duplicate spawn allocated another copy'
  pass "native $kind selects exact accepted source on divergence and refuses duplicate spawn"
done

for scenario in tmux-manual tmux-rebased tmux-spend tmux-close tmux-retain herdr-manual; do
  backend=${scenario%%-*}
  retirement=${scenario#*-}
  case "$retirement" in rebased|spend) retirement=manual ;; esac
  make_case "missing-$scenario"
  printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
  id=missing-endpoint
  if [ "$retirement" != manual ]; then
    printf 'markdown\n' > "$HOME_DIR/config/backlog-backend"
    fm_test_tasks_toml "$HOME_DIR/.tasks.toml"
    printf '# Backlog\n\n## In flight\n\n## Queued\n\n## Done\n' > "$HOME_DIR/data/backlog.md"
    tasks-axi add "$id" fixture --kind ship --file "$HOME_DIR/data/backlog.md" >/dev/null || fail 'could not seed native backlog'
    tasks-axi start "$id" --file "$HOME_DIR/data/backlog.md" >/dev/null || fail 'could not start native backlog row'
    if [ "$retirement" = retain ]; then
      tasks-axi hold "$id" --reason 'captain decision pending' --kind captain --file "$HOME_DIR/data/backlog.md" >/dev/null || fail 'could not hold native backlog row'
    fi
  fi
  allocate "$id" || fail 'missing endpoint fixture allocation failed'
  WT=$FM_GIT_WORKTREE_PATH
  native_mode=local-only
  if [ "$scenario" = tmux-spend ]; then
    : > "$HOME_DIR/config/pipeline-spend"
    git -C "$WT" switch -qc "fm/$id"
  fi
  if [ "$scenario" = tmux-rebased ]; then
    native_mode=no-mistakes
    git clone -q --bare "$PROJ" "$CASE/origin.git"
    git -C "$PROJ" remote add origin "$CASE/origin.git"
    git -C "$PROJ" fetch -q origin
    printf 'original delivery\n' > "$WT/delivered"
    git -C "$WT" add delivered
    git -C "$WT" -c user.name=test -c user.email=test@example.invalid commit -qm original
    original=$(git -C "$WT" rev-parse HEAD)
    git -C "$WT" push -q origin HEAD:refs/heads/original-submission
    git -C "$PROJ" fetch -q origin
    printf 'new base\n' > "$PROJ/advance"
    git -C "$PROJ" add advance
    git -C "$PROJ" -c user.name=test -c user.email=test@example.invalid commit -qm advance
    git -C "$PROJ" -c user.name=test -c user.email=test@example.invalid cherry-pick "$original" >/dev/null
    native_pr_head=$(git -C "$PROJ" rev-parse HEAD)
    git -C "$PROJ" push -q origin "$MAIN"
  fi
  fakebin=$(fm_fakebin "$CASE/fake")
  cat > "$fakebin/gh" <<'SH'
#!/usr/bin/env bash
if [ "$1 $2" = 'pr view' ]; then
  printf '%s\t%s\thttps://example.invalid/fixture/project/pull/1\n' "${FM_TEST_NATIVE_PR_STATE:-MERGED}" "${FM_TEST_NATIVE_PR_HEAD:?}"
else
  exit 1
fi
SH
  chmod +x "$fakebin/gh"
  cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
# Model the detached update checker observed in no-mistakes v1.84.0.
if [ "$*" = axi ] && [ "${NO_MISTAKES_NO_UPDATE_CHECK:-}" != 1 ]; then
  (exec sleep 1) </dev/null >/dev/null 2>&1 &
fi
exit 0
SH
  cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in
  list-windows)
    [ "${FM_TEST_ENDPOINT_UNREADABLE:-0}" != 1 ] || exit 1
    printf 'main\n' ;;
  display-message) exit 1 ;;
esac
SH
  cat > "$fakebin/herdr" <<'SH'
#!/usr/bin/env bash
case "$1 $2" in
  'pane get')
    if [ "${FM_TEST_ENDPOINT_UNREADABLE:-0}" = 1 ]; then
      printf 'not-json\n'
    else
      printf '%s\n' '{"error":{"code":"pane_not_found"}}'
    fi
    exit 1 ;;
  'session list') printf '{"sessions":[{"name":"native-fixture","running":true,"socket_path":"%s"}]}\n' "${FM_TEST_HERDR_SOCKET:?}" ;;
  'status --json') printf '%s\n' '{"server":{"running":true}}' ;;
  'workspace list') printf '%s\n' '{"result":{"workspaces":[]}}' ;;
  'pane process-info') exit 1 ;;
esac
SH
  chmod +x "$fakebin/no-mistakes" "$fakebin/tmux" "$fakebin/herdr"
  target="native-fixture:fm-$id"
  [ "$backend" != herdr ] || target=native-fixture:w1:p1
  fm_write_meta "$HOME_DIR/state/$id.meta" \
    "window=$target" "endpoint_task_id=$id" "backend=$backend" \
    "worktree=$WT" "project=$PROJ" 'kind=ship' "mode=$native_mode" \
    'spawn_gen=s1792922400.123.456' 'allocator=git'
  if [ "$scenario" = tmux-rebased ]; then
    printf 'pr=https://example.invalid/fixture/project/pull/1\n' >> "$HOME_DIR/state/$id.meta"
  fi
  if [ "$backend" = herdr ]; then
    printf '%s\n' 'herdr_session=native-fixture' 'herdr_workspace_id=w1' \
      'herdr_tab_id=w1:t1' 'herdr_pane_id=w1:p1' >> "$HOME_DIR/state/$id.meta"
  fi
  run_native_teardown() {
    env PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 \
      FM_TEST_HERDR_SOCKET="$CASE/herdr.sock" \
      FM_TEST_NATIVE_PR_HEAD="${native_pr_head:-}" \
      bash "$ROOT/bin/fm-teardown.sh" "$id"
  }
  if out=$(FM_TEST_ENDPOINT_UNREADABLE=1 run_native_teardown 2>&1); then
    fail "$backend unreadable endpoint permitted native removal"
  fi
  assert_contains "$out" 'live or unverified endpoint' "$backend refused for the wrong reason"
  if [ "$scenario" = tmux-rebased ]; then
    if out=$(FM_TEST_NATIVE_PR_STATE=OPEN run_native_teardown 2>&1); then
      fail 'native teardown accepted an unmerged rebased PR'
    fi
    assert_contains "$out" 'not proven landed' 'open PR failed for an unrelated reason'
    git -C "$WT" switch -qc retained-unique-work
    printf 'unique work\n' > "$WT/unique"
    git -C "$WT" add unique
    git -C "$WT" -c user.name=test -c user.email=test@example.invalid commit -qm unique
    git -C "$WT" push -q origin HEAD:refs/heads/unique-published
    git -C "$PROJ" fetch -q origin
    if out=$(run_native_teardown 2>&1); then
      fail 'native teardown discarded unique work beside the merged patch'
    fi
    assert_contains "$out" 'not proven landed' 'unique commit failed for an unrelated reason'
    [ -f "$WT/unique" ] && [ -f "$HOME_DIR/state/$id.meta" ] || fail 'unique-work refusal lost evidence'
    git -C "$WT" checkout -q --detach "$original"
  fi
  bash -c 'cd "$1" && printf ready > "$2" && exec sleep 60' _ "$WT" "$CASE/ready" &
  owner=$!
  for _ in $(seq 1 100); do [ ! -f "$CASE/ready" ] || break; sleep 0.01; done
  [ -f "$CASE/ready" ] || { kill "$owner"; wait "$owner" || true; fail 'copy owner did not start'; }
  rc=0
  out=$(run_native_teardown 2>&1) || rc=$?
  alive=0
  kill -0 "$owner" 2>/dev/null && alive=1
  kill "$owner" 2>/dev/null || true
  wait "$owner" 2>/dev/null || true
  [ "$rc" != 0 ] && [ "$alive" = 1 ] || fail "$backend missing endpoint discarded a live copy"
  assert_contains "$out" 'native copy still has processes' "$backend never reached native process proof"
  [ -d "$WT" ] && [ -f "$HOME_DIR/state/$id.meta" ] && [ -f "$HOME_DIR/state/$id.git-worktree" ] \
    || fail "$backend process refusal lost copy or records"
  bash "$ROOT/bin/fm-busy-event.sh" arm "$HOME_DIR/state" "$id" >/dev/null || fail 'could not arm retirement fixture'
  real_rm=$(command -v rm)
  cat > "$fakebin/rm" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ -n "${FM_TEST_RETIRE_PATH:-}" ] && [ "$arg" = "$FM_TEST_RETIRE_PATH" ]; then
    printf 'fixture retirement failure\n' >&2
    exit 1
  fi
done
exec "${FM_TEST_REAL_RM:?}" "$@"
SH
  chmod +x "$fakebin/rm"
  cp "$fakebin/rm" "$CASE/rm-shim"
  for artifact in busy-gen meta; do
    rc=0
    out=$(FM_TEST_REAL_RM="$real_rm" FM_TEST_RETIRE_PATH="$HOME_DIR/state/$id.$artifact" run_native_teardown 2>&1) || rc=$?
    [ "$rc" != 0 ] || fail "$backend $artifact fault did not fail teardown"
    case "$artifact" in
      busy-gen) assert_contains "$out" 'busy-state retirement failed' 'busy fault did not reach busy retirement' ;;
      meta) assert_contains "$out" 'task record could not be removed' 'metadata fault did not reach record retirement' ;;
    esac
    [ ! -e "$WT" ] && [ -f "$HOME_DIR/state/$id.meta" ] && [ -f "$HOME_DIR/state/$id.git-worktree" ] \
      || fail "$backend $artifact failure lost retry ownership evidence"
  done
  run_native_replay() {
    env PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
      FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
      FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_BOOTSTRAP_NETWORK=skip \
      FM_TEST_HERDR_SOCKET="$CASE/herdr.sock" bash "$ROOT/bin/fm-bootstrap.sh"
  }
  real_queue=$(command -v tasks-axi)
  if [ "$retirement" != manual ]; then
    cat > "$fakebin/tasks-axi" <<'SH'
#!/usr/bin/env bash
case "$1" in done|reopen) echo 'fixture queue retirement failure' >&2; exit 1 ;; esac
exec "${FM_TEST_REAL_QUEUE:?}" "$@"
SH
    chmod +x "$fakebin/tasks-axi"
  fi
  rc=0
  out=$(FM_TEST_REAL_RM="$real_rm" FM_TEST_REAL_QUEUE="$real_queue" \
    FM_TEST_RETIRE_PATH="$HOME_DIR/state/$id.git-worktree" run_native_teardown 2>&1) || rc=$?
  [ "$rc" != 0 ] && [ ! -e "$HOME_DIR/state/$id.meta" ] \
    && [ -f "$HOME_DIR/state/$id.git-worktree" ] && [ -f "$HOME_DIR/state/$id.backlog-close" ] \
    || fail "$scenario did not retain retirement evidence after metadata disappeared: $out"
  "$real_rm" -f "$fakebin/rm" "$fakebin/tasks-axi"
  if allocate "$id"; then fail 'pending retirement was reused as an unpublished reservation'; fi
  cp "$HOME_DIR/state/$id.git-worktree" "$CASE/reservation"
  alternate=$(printf 'other base\n' | git -C "$PROJ" -c user.name=Tests -c user.email=tests@example.invalid commit-tree "$BASE^{tree}" -p "$BASE")
  sed "s/^base=.*/base=$alternate/" "$CASE/reservation" > "$HOME_DIR/state/$id.git-worktree"
  out=$(run_native_replay 2>&1)
  [ -f "$HOME_DIR/state/$id.git-worktree" ] && [ -f "$HOME_DIR/state/$id.backlog-close" ] \
    || fail "$scenario replay retired changed ownership evidence"
  cp "$CASE/reservation" "$HOME_DIR/state/$id.git-worktree"
  mkdir -p "$WT"
  printf 'preserve\n' > "$WT/sentinel"
  out=$(run_native_replay 2>&1)
  [ -f "$WT/sentinel" ] && [ -f "$HOME_DIR/state/$id.git-worktree" ] \
    || fail "$scenario replay removed a reappeared unknown path"
  rm "$WT/sentinel"
  rmdir "$WT" "${WT%/worktree}"
  cp "$CASE/rm-shim" "$fakebin/rm"
  out=$(FM_TEST_REAL_RM="$real_rm" FM_TEST_RETIRE_PATH="$HOME_DIR/state/$id.backlog-close" run_native_replay 2>&1)
  [ ! -e "$HOME_DIR/state/$id.git-worktree" ] && [ -f "$HOME_DIR/state/$id.backlog-close" ] \
    || fail "$scenario did not preserve replay after reservation retirement"
  "$real_rm" "$fakebin/rm"
  if allocate "$id"; then fail 'pending final retirement marker allowed task reuse'; fi
  out=$(run_native_replay 2>&1)
  expect_code 0 "$?" "$scenario native retirement replay failed: $out"
  [ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$id.meta" ] && [ ! -e "$HOME_DIR/state/$id.git-worktree" ] \
    || fail "$backend missing endpoint cleanup left copy or records"
  [ ! -e "$HOME_DIR/state/$id.backlog-close" ] || fail "$scenario replay left its retirement marker"
  git -C "$PROJ" update-ref "refs/heads/$MAIN" "$alternate"
  BASE=$alternate
  allocate "$id" || fail "$scenario replay stranded future allocation"
  [ "$(git -C "$FM_GIT_WORKTREE_PATH" rev-parse HEAD)" = "$BASE" ] || fail 'completed task reused its retired base'
  remove_copy "$id" || fail 'fresh post-retirement allocation did not clean up'
  pass "native $backend teardown retries a missing endpoint but preserves unreadable and live owners"
done

make_case preserve
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
id=preserve-leftovers
allocate "$id" || fail 'preservation fixture allocation failed'
WT=$FM_GIT_WORKTREE_PATH
KEEP="$HOME_DIR/data/$id/preserved-artifacts"
fakebin=$(fm_fakebin "$CASE/fake")
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$1" in list-windows) printf 'main\n' ;; display-message) exit 1 ;; esac
SH
cat > "$fakebin/no-mistakes" <<'SH'
#!/usr/bin/env bash
exit 0
SH
chmod +x "$fakebin/tmux" "$fakebin/no-mistakes"
fm_write_meta "$HOME_DIR/state/$id.meta" \
  "window=native-fixture:fm-$id" "endpoint_task_id=$id" 'backend=tmux' \
  "worktree=$WT" "project=$PROJ" 'kind=ship' 'mode=local-only' \
  'spawn_gen=s1792922400.123.456' 'allocator=git'
run_preserve_teardown() {
  env PATH="$fakebin:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" \
    FM_STATE_OVERRIDE="$HOME_DIR/state" FM_DATA_OVERRIDE="$HOME_DIR/data" \
    FM_CONFIG_OVERRIDE="$HOME_DIR/config" FM_TEARDOWN_GUARD_DONE=1 \
    bash "$ROOT/bin/fm-teardown.sh" "$id" "$@"
}
printf '__pycache__/\n' >> "$PROJ/.git/info/exclude"
mkdir -p "$WT/__pycache__" "$WT/.cache"
printf 'bytecode\n' > "$WT/__pycache__/mod.pyc"
fm_git_init_commit "$WT/.cache/clone"
clone_head=$(git -C "$WT/.cache/clone" rev-parse HEAD)
leftovers_intact() {
  [ "$(cat "$WT/__pycache__/mod.pyc")" = bytecode ] && [ -d "$WT/.cache/clone/.git" ] \
    && [ -f "$HOME_DIR/state/$id.meta" ]
}
if out=$(run_preserve_teardown 2>&1); then fail 'leftover generated artifacts were discarded'; fi
assert_contains "$out" '--preserve-untracked' 'clean refusal did not name the guarded next action'
leftovers_intact || fail 'plain refusal changed leftovers or task records'
if out=$(run_preserve_teardown --preserve-untracked .cache 2>&1); then fail 'an unnamed leftover was left behind'; fi
assert_contains "$out" 'not named' 'partial naming refused for the wrong reason'
leftovers_intact && [ ! -e "$KEEP/files" ] || fail 'partial naming moved something before refusing'
printf 'unique edit\n' >> "$WT/README.md"
if out=$(run_preserve_teardown --preserve-untracked .cache --preserve-untracked __pycache__ 2>&1); then
  fail 'tracked unique work was retired beside generated artifacts'
fi
assert_contains "$out" 'tracked changes are unique work' 'tracked edit refused for the wrong reason'
leftovers_intact && grep -q 'unique edit' "$WT/README.md" && [ ! -e "$KEEP/files" ] \
  || fail 'unique-work refusal moved or lost content'
git -C "$WT" checkout -q -- README.md
for name in ../outside README.md /abs .cache/../__pycache__; do
  if out=$(run_preserve_teardown --preserve-untracked "$name" 2>&1); then fail "unsafe name $name was accepted"; fi
  leftovers_intact && [ ! -e "$KEEP/files" ] || fail "unsafe name $name moved content"
done
if out=$(run_preserve_teardown --force --preserve-untracked .cache 2>&1); then fail 'preservation combined with force'; fi
real_mv=$(command -v mv)
cat > "$fakebin/mv" <<'SH'
#!/usr/bin/env bash
for arg in "$@"; do
  if [ "$arg" = "${FM_TEST_FAIL_MV_TARGET:-}" ]; then printf 'fixture interruption\n' >&2; exit 1; fi
done
exec "${FM_TEST_REAL_MV:?}" "$@"
SH
chmod +x "$fakebin/mv"
if out=$(FM_TEST_REAL_MV="$real_mv" FM_TEST_FAIL_MV_TARGET="$KEEP/receipt" \
  run_preserve_teardown --preserve-untracked .cache --preserve-untracked __pycache__ 2>&1); then
  fail 'interrupted preservation reported completion'
fi
"$real_mv" "$fakebin/mv" "$CASE/mv-shim"
[ -d "$WT" ] && [ -f "$HOME_DIR/state/$id.meta" ] && [ -f "$HOME_DIR/state/$id.git-worktree" ] \
  || fail 'interrupted preservation retired the task before the copy was removed'
[ ! -e "$WT/.cache" ] && [ -d "$KEEP/files/.cache/clone/.git" ] && [ ! -e "$KEEP/receipt" ] \
  || fail 'interruption fixture did not stop between move and receipt'
[ "$(cat "$WT/__pycache__/mod.pyc")" = bytecode ] || fail 'interruption moved past the failed path'
mkdir -p "$KEEP/files/__pycache__"
printf 'stale\n' > "$KEEP/files/__pycache__/mod.pyc"
if out=$(run_preserve_teardown --preserve-untracked .cache --preserve-untracked __pycache__ 2>&1); then
  fail 'preservation overwrote an existing destination'
fi
assert_contains "$out" 'nothing overwritten' 'existing destination refused for the wrong reason'
[ "$(cat "$WT/__pycache__/mod.pyc")" = bytecode ] && [ "$(cat "$KEEP/files/__pycache__/mod.pyc")" = stale ] \
  || fail 'no-overwrite refusal changed either copy'
rm -r "$KEEP/files/__pycache__"
out=$(run_preserve_teardown --preserve-untracked .cache --preserve-untracked __pycache__ 2>&1)
expect_code 0 "$?" "restarted preservation did not complete teardown: $out"
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$id.meta" ] && [ ! -e "$HOME_DIR/state/$id.git-worktree" ] \
  || fail 'restarted preservation left the copy or task records'
[ "$(cat "$KEEP/files/__pycache__/mod.pyc")" = bytecode ] \
  && [ "$(git -C "$KEEP/files/.cache/clone" rev-parse HEAD)" = "$clone_head" ] \
  || fail 'preserved artifacts lost content'
[ "$(cut -f3 "$KEEP/receipt" | sort | tr '\n' ' ')" = '.cache __pycache__ ' ] \
  || fail "receipt does not record each preserved path once: $(cat "$KEEP/receipt")"
pass 'native teardown preserves named generated leftovers, refuses unique or unnamed work, and resumes after interruption'

fm_live_gate default-on FM_NATIVE_TMUX_LIVE_E2E tmux pgrep lsof

LAB_HOME_HELPER=${LAB_HOME_HELPER:-$ROOT/bin/fm-lab-home.sh}
HOME_DIR="$TMP_ROOT/tmux-home"
PROJ="$TMP_ROOT/tmux-project"
COPY_ROOT="$TMP_ROOT/tmux-copies"
"$LAB_HOME_HELPER" create "$HOME_DIR" >/dev/null || fail 'could not mark tmux lab home'
LAB_TMUX_DIR=$("$LAB_HOME_HELPER" tmux-dir "$HOME_DIR") || fail 'could not create private tmux socket dir'
REAL_TMUX=$(command -v tmux)
TMUX_SOCKET="native-$$"
cleanup_native_tmux() {
  local status=$?
  TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$TMUX_SOCKET" kill-server >/dev/null 2>&1 || true
  "$LAB_HOME_HELPER" teardown "$HOME_DIR" || status=1
  fm_test_cleanup
  exit "$status"
}
trap cleanup_native_tmux EXIT
fm_git_init_commit "$PROJ"
printf 'git\n' > "$HOME_DIR/config/worktree-allocator"
printf '%s\n' "$COPY_ROOT" > "$HOME_DIR/config/git-worktree-root"
printf 'manual\n' > "$HOME_DIR/config/backlog-backend"
tmux_shim=$(fm_fakebin "$TMP_ROOT/native-tmux-shim")
{
  printf '#!/usr/bin/env bash\n'
  printf 'export TMUX_TMPDIR=%q\nexec %q -L %q "$@"\n' "$LAB_TMUX_DIR" "$REAL_TMUX" "$TMUX_SOCKET"
} > "$tmux_shim/tmux"
chmod +x "$tmux_shim/tmux"
TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$TMUX_SOCKET" -f /dev/null \
  new-session -d -s firstmate -n main -c "$PROJ" /bin/sh || fail 'could not start private tmux lab'
TMUX_TMPDIR="$LAB_TMUX_DIR" "$REAL_TMUX" -L "$TMUX_SOCKET" set-option -g default-command '/bin/bash --noprofile --norc'
id="native-tmux-$$"
FM_TEST_CLEANUP_DIRS+=("/tmp/fm-$id")
fm_test_spawn_brief "$HOME_DIR" "$id"
marker="$TMP_ROOT/tmux-worker"
# shellcheck disable=SC2016
printf -v raw 'bash -c '\''pwd -P >> "$1"; sleep 60'\'' _ %q' "$marker"
out=$(env PATH="$tmux_shim:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_SPAWN_NO_GUARD=1 \
  bash "$ROOT/bin/fm-spawn.sh" "$id" "$PROJ" "$raw" --mode local-only --yolo off --backend tmux 2>&1)
expect_code 0 "$?" "real native tmux launch failed: $out"
WT="$COPY_ROOT/$id/worktree"
for _ in $(seq 1 30); do [ ! -s "$marker" ] || break; sleep 0.1; done
[ "$(cat "$marker")" = "$WT" ] || fail 'native tmux worker did not execute once in isolated copy'
if out=$(env PATH="$tmux_shim:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
  bash "$ROOT/bin/fm-teardown.sh" "$id" 2>&1); then fail 'native tmux teardown killed a busy owner'; fi
env PATH="$tmux_shim:$PATH" tmux send-keys -t "firstmate:fm-$id" C-c
for _ in $(seq 1 30); do
  # Positional parameters are supplied to the nested Bash classifier.
  # shellcheck disable=SC2016
  state=$(env PATH="$tmux_shim:$PATH" bash -c '. "$1/bin/fm-backend.sh"; fm_backend_agent_state tmux "$2"' _ "$ROOT" "firstmate:fm-$id")
  [ "$state" != dead ] || break
  sleep 0.1
done
[ "$state" = dead ] || fail 'native tmux marker did not return to idle shell'
out=$(env PATH="$tmux_shim:$PATH" FM_HOME="$HOME_DIR" FM_ROOT_OVERRIDE="$ROOT" FM_TEARDOWN_GUARD_DONE=1 \
  bash "$ROOT/bin/fm-teardown.sh" "$id" 2>&1)
expect_code 0 "$?" "real clean native tmux teardown failed: $out"
[ ! -e "$WT" ] && [ ! -e "$HOME_DIR/state/$id.meta" ] && [ ! -e "$HOME_DIR/state/$id.git-worktree" ] \
  || fail 'native tmux cleanup left copy/records'
pass 'real native tmux worker owns one isolated copy; busy refusal and clean teardown preserve lifecycle guards'
