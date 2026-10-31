#!/usr/bin/env bash
source .test-live/common-remote.sh
ID=sibling
CASE="$RUN/$ID"
export FM_HOME="$CASE/home"
PROJ="$ROOT/.test-live/remote-project"
step bash bin/fm-lab-home.sh create "$FM_HOME"
printf 'markdown\n' > "$FM_HOME/config/backlog-backend"
printf 'backend = "markdown"\n[markdown]\npath = "data/backlog.md"\n' > "$FM_HOME/.tasks.toml"
printf '# Backlog\n\n## In flight\n\n- **sibling** - Delivered through sibling PR. (kind: ship)\n\n## Queued\n\n## Done\n' > "$FM_HOME/data/backlog.md"
git -C "$PROJ" checkout -q main
head=$(git -C "$PROJ" rev-parse delivered)
fm_git_worktree_allocate "$FM_HOME/state" "$ID" "$FM_HOME" "$PROJ" "$CASE/copies" "$head" refs/heads/delivered
WT=$FM_GIT_WORKTREE_PATH
printf 'window=fm-lab:fm-%s\nendpoint_task_id=%s\nbackend=tmux\nworktree=%s\nproject=%s\nkind=ship\nmode=local-only\nbranch=fm/sibling\nspawn_gen=s1.sibling\nallocator=git\nbase_branch=main\n' "$ID" "$ID" "$WT" "$PROJ" > "$FM_HOME/state/$ID.meta"
step gh-axi pr view 13 --repo runkaiz/firstmate-lite
refuse td --landed-pr https://github.com/runkaiz/firstmate-lite/pull/13 --landed-head "$(git -C "$PROJ" rev-parse main)"
td --landed-pr https://github.com/runkaiz/firstmate-lite/pull/13 --landed-head "$head"
closed
grep -F "landed via https://github.com/runkaiz/firstmate-lite/pull/13 at $head" "$FM_HOME/data/backlog.md"
echo 'SCENARIO PASS: real merged sibling PR proof closes automatic queue with exact publication note; mismatched head refuses'
