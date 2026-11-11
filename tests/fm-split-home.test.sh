#!/usr/bin/env bash
# Exercise two homes installed from one local Git fixture, then run a task
# from the installed entry points with native Git copies and a stubbed tmux.
set -eu

# shellcheck source=tests/fixtures.sh
. "$(dirname "${BASH_SOURCE[0]}")/fixtures.sh"

tmp=$(fm_test_tmproot fm-split-home)
seed="$tmp/origin"
home="$tmp/private home"
other="$tmp/other home"
code="$tmp/install data/firstmate"
project="$home/projects/sample"
task=split-home-task
copies="$tmp/task copies"
copy="$copies/$task/worktree"
fakebin=$(fm_fakebin "$tmp/fake")

fm_git_identity
git init -q -b main "$seed"
cp -R -P "$ROOT/"{bin,docs,.agents,.claude,.codex,.pi} "$seed/"
cp "$ROOT/"{AGENTS.md,.gitignore} "$seed/"
printf '#!/bin/sh\nexit 0\n' > "$seed/bin/split-action.sh"
chmod +x "$seed/bin/split-action.sh"
git -C "$seed" add .
git -C "$seed" commit -qm initial

export GIT_CONFIG_COUNT=1
export GIT_CONFIG_KEY_0="url.file://$seed.insteadOf"
export GIT_CONFIG_VALUE_0=https://github.com/runkaiz/firstmate-lite.git
export XDG_DATA_HOME="$tmp/install data"
unset FM_HOME FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_STATE_OVERRIDE FM_PROJECTS_OVERRIDE
unset FM_QUEUE_TEST_CLI

installer="$ROOT/bin/fm-install.sh"
"$installer" "$home" >/dev/null
"$installer" "$other" >/dev/null
printf 'keep my notes\n' > "$home/data/learnings.md"
"$installer" "$home" >/dev/null
assert_equals 'keep my notes' "$(cat "$home/data/learnings.md")" 'reinstall preserves private records'
for dir in data state config projects; do
  [ -d "$home/$dir" ] && [ -d "$other/$dir" ] || fail "installer did not initialize $dir"
  assert_absent "$code/$dir" "installer put $dir in the shared checkout"
done
assert_absent "$home/.git" 'installer created another Git checkout'
[ "$home/CLAUDE.md" -ef "$code/AGENTS.md" ] || fail 'Claude did not get the same instructions directly'
[ "$other/bin" -ef "$code/bin" ] || fail 'second home does not use the shared tools'

mkdir -p "$tmp/collision"
printf 'local instructions\n' > "$tmp/collision/AGENTS.md"
if out=$("$installer" "$tmp/collision" 2>&1); then fail 'installer overwrote local instructions'; fi
assert_contains "$out" 'would overwrite' 'collision refusal'
assert_equals 'local instructions' "$(cat "$tmp/collision/AGENTS.md")" 'collision preserves instructions'
pass 'installer shares one checkout across homes and preserves existing files'

in_home() (
  cd "$1"
  shift
  bin/fm-start.sh "$@"
)

in_home "$other" bin/fm-procevent-when.sh arm update-binding --interval 60 --stable 1 \
  --condition false --action "$code/bin/split-action.sh" >/dev/null
cp -R "$home/state" "$tmp/home-state-before"
cp -R "$other/state" "$tmp/other-state-before"
printf '\nFirstmate split update fixture.\n' >> "$seed/AGENTS.md"
printf '# fixture update\n' >> "$seed/bin/split-action.sh"
git -C "$seed" commit -qam update
out=$(in_home "$other" bin/fm-update.sh)
assert_contains "$out" 'firstmate: updated ' 'shared update did not advance'
assert_contains "$out" 'reread-firstmate: yes' 'shared update did not report instruction changes'
assert_grep 'Firstmate split update fixture' "$home/AGENTS.md" 'second home did not see new instructions'
diff -r "$tmp/home-state-before" "$home/state" || fail 'updating code changed the first home'
diff -r "$tmp/other-state-before" "$other/state" || fail 'updating code changed the second home'
pass 'shared update leaves both homes and registered watch bindings untouched'

fm_test_fake_tmux_spawn "$fakebin"
mv "$fakebin/tmux" "$fakebin/tmux-spawn"
cat > "$fakebin/tmux" <<'SH'
#!/usr/bin/env bash
case "$*" in
  *'#{pane_current_command}'*) cat "$FM_SPLIT_PANE"; exit ;;
  *'#{cursor_y}'*) printf '1\n'; exit ;;
esac
case "$1" in
  capture-pane) printf '╭────╮\n│    │\n╰────╯\n' ;;
  list-windows) cat "$FM_SPLIT_WINDOW" ;;
  new-window)
    printf 'fm-split-home-task\n' > "$FM_SPLIT_WINDOW"
    printf '@1\n'
    ;;
  send-keys)
    printf '%s\n' "$*" >> "$FM_SPLIT_KEYS"
    exec "$(dirname "$0")/tmux-spawn" "$@"
    ;;
  *) exec "$(dirname "$0")/tmux-spawn" "$@" ;;
esac
SH
chmod +x "$fakebin/tmux"
fm_test_fake_gh "$fakebin"
fm_test_fake_gh_axi "$fakebin"
fm_test_fake_no_mistakes "$fakebin"
cp "$(command -v bash)" "$fakebin/codex"
export PATH="$fakebin:$PATH" FM_BACKEND=tmux TMUX=fake,1,0
export FM_FAKE_PANE_PATH="$copy" FM_SPLIT_PANE="$tmp/pane" FM_SPLIT_KEYS="$tmp/keys"
export FM_SPLIT_WINDOW="$tmp/window"
export FM_STARTUP_NETWORK_TIMEOUT=4
: > "$FM_SPLIT_WINDOW"
printf 'codex\n' > "$FM_SPLIT_PANE"

out=$(in_home "$home" codex -c 'bin/fm-sessionstart-run.sh --source startup; exit $?')
assert_contains "$out" "SESSION START - $home" 'session start did not run from the installed home'
assert_contains "$out" 'keep my notes' 'session start did not read private data'
[ -s "$home/state/.session-start-complete" ] || fail 'session start did not complete as lock owner'
out=$(FM_TASK_ID=worker in_home "$other" bin/fm-sessionstart-run.sh --source startup)
assert_equals '' "$out" 'a worker inheriting the primary environment ran session start'

fm_git_init_commit "$project"
printf -- '- sample [local-only]\n' > "$home/data/projects.md"
printf 'git\n' > "$home/config/worktree-allocator"
printf '%s\n' "$copies" > "$home/config/git-worktree-root"
in_home "$home" bin/fm-queue.sh add "$task" 'Exercise split-home delivery' --kind ship --repo sample >/dev/null
in_home "$home" bin/fm-brief.sh "$task" sample --mode local-only >/dev/null
brief="$home/data/$task/brief.md"
sed -e 's/{TASK}/Exercise split-home delivery./' -e 's/{FIRSTMATE_SPEC}/Create a fixture file./' "$brief" > "$tmp/brief"
mv "$tmp/brief" "$brief"
out=$(in_home "$home" bin/fm-spawn.sh "$task" projects/sample codex --mode local-only --yolo off --backend tmux 2>&1) ||
  fail "spawn from installed home failed: $out"
assert_grep "worktree=$copy" "$home/state/$task.meta" 'spawn lost the isolated project copy'
out=$(in_home "$home" bin/fm-send.sh "$task" 'split home steering' 2>&1) || fail "steering failed: $out"
assert_grep 'split home steering' "$home/state/$task.inbox/001.msg" 'steer did not reach the private inbox'
out=$(in_home "$home" bin/fm-control.sh "$task" interrupt 2>&1) || fail "interrupt failed: $out"
assert_grep Escape "$FM_SPLIT_KEYS" 'control did not reach the recorded endpoint'
git -C "$copy" checkout -qb "fm/$task"
printf 'delivery\n' > "$copy/delivery.txt"
git -C "$copy" add delivery.txt
git -C "$copy" commit -qm delivery
printf 'done: ready for local merge\n' >> "$home/state/$task.status"
out=$(in_home "$home" bin/fm-merge-local.sh "$task" 2>&1) || fail "local merge failed: $out"
assert_equals 'delivery' "$(cat "$project/delivery.txt")" 'local merge missed the selected project'
: > "$FM_SPLIT_WINDOW"
out=$(in_home "$home" bin/fm-teardown.sh "$task" 2>&1) || fail "teardown failed: $out"
assert_absent "$copy" 'teardown left the isolated copy'
assert_absent "$home/state/$task.meta" 'teardown left the active task record'
assert_absent "$other/state/$task.meta" 'task state leaked into the other home'
assert_absent "$code/state" 'lifecycle created private state in the shared checkout'
out=$(in_home "$home" bin/fm-queue.sh show "$task")
assert_contains "$out" 'state: done' 'teardown did not close the private backlog row'
pass 'startup, spawn, steer, interrupt, local merge and teardown use the installed home'
