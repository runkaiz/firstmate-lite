#!/usr/bin/env bash
set -eu
ROOT=/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M6DETVKKZ59NZBMVZXJ557KK
D=$ROOT/.browser-validation
LAB=$D/lab
"$ROOT/bin/fm-lab-home.sh" create "$LAB"
mkdir -p "$D/project" "$D/copies"
git -C "$D/project" init -q -b main
printf 'browser cleanup fixture\n' > "$D/project/README.md"
git -C "$D/project" add README.md
git -C "$D/project" -c user.name=Validation -c user.email=validation@example.invalid -c commit.gpgsign=false commit -qm initial
printf 'manual\n' > "$LAB/config/backlog-backend"
printf 'git\n' > "$LAB/config/worktree-allocator"
printf '%s\n' "$D/copies" > "$LAB/config/git-worktree-root"
printf -- '- project [local-only]\n' > "$LAB/data/projects.md"
. "$ROOT/bin/fm-git-worktree-lib.sh"
base=$(git -C "$D/project" rev-parse HEAD)
fm_git_worktree_allocate "$LAB/state" browser-cleanup "$LAB" "$D/project" "$D/copies" "$base" refs/heads/main
cat > "$LAB/state/browser-cleanup.meta" <<EOF
window=fm-lab-browser:fm-browser-cleanup
endpoint_task_id=browser-cleanup
backend=tmux
worktree=$FM_GIT_WORKTREE_PATH
project=$D/project
kind=ship
mode=local-only
spawn_gen=s1792922400.123.456
allocator=git
EOF
tmux -S "$ROOT/.browser-socket" new-session -d -s fm-lab-browser -n main -c "$D" 'sleep 600'
echo "$FM_GIT_WORKTREE_PATH"
