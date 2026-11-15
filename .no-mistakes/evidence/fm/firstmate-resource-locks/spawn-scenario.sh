#!/usr/bin/env bash
set -eu
repo_root=/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ
evidence=/home/runkai/.no-mistakes/evidence/01M7E5G3VE4WRF2AH7TSMB9MDJ
exec > "$evidence/uncapped-spawn-live.log" 2>&1
echo 'Real primary is executing this scenario on its private tmux socket.'
printf 'FM_HOME=%s\nTMUX=%s\n' "$FM_HOME" "$TMUX"
test "$FM_HOME" = "$repo_root/l"
project="$FM_HOME/projects/demo"
mkdir -p "$project" "$FM_HOME/tmp"
export TMPDIR="$FM_HOME/tmp"
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1
git -C "$project" init -q -b main
printf 'Disposable live admission fixture\n' > "$project/README.txt"
git -C "$project" add README.txt
git -C "$project" -c user.name=Test -c user.email=test@example.invalid commit -qm initial
printf 'git\n' > "$FM_HOME/config/worktree-allocator"
printf '%s/copies\n' "$(cd "$repo_root/.test-live" && pwd -P)" > "$FM_HOME/config/git-worktree-root"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf -- '- demo [local-only]\n' > "$FM_HOME/data/projects.md"
printf 'demo 1\n' > "$FM_HOME/config/project-capacity"
printf 'suite 2 22:00-09:00=1 full suites\ngpu 1 GPU jobs\n' > "$FM_HOME/config/resource-locks"
cp "$FM_HOME/config/project-capacity" "$FM_HOME/before-capacity"
# The native CLI responds with authenticated output and then keeps its pane
# around, representing the idle/waiting workers the retired cap counted.
raw="env -u CLAUDECODE -u CLAUDE_CODE_ENTRYPOINT claude -p --no-session-persistence --setting-sources '' --strict-mcp-config --tools '' --system-prompt 'Reply only AUTHENTICATED_WORKER_READY. Do not access files, execute commands, or change anything.' 'Reply now'; sleep 120"
for n in 1 2 3; do
  id="resource-live-$$-$n"
  printf '%s\n' "$id" >> "$FM_HOME/ids"
  echo "COMMAND: fm-brief.sh $id demo --mode local-only"
  "$repo_root/bin/fm-brief.sh" "$id" demo --mode local-only
  python3 - "$FM_HOME/data/$id/brief.md" <<'PY'
import sys
from pathlib import Path
p = Path(sys.argv[1])
p.write_text(p.read_text().replace('{TASK}', 'Verify uncapped dispatch in a disposable lab.').replace('{FIRSTMATE_SPEC}', 'Run only the supplied authenticated readiness probe.'))
PY
  echo "COMMAND: fm-spawn.sh $id $project <real Claude print command> --mode local-only --yolo off --backend tmux"
  FM_SPAWN_NO_GUARD=1 "$repo_root/bin/fm-spawn.sh" "$id" "$project" "$raw" --mode local-only --yolo off --backend tmux
  test -f "$FM_HOME/state/$id.meta"
  cat "$FM_HOME/state/$id.meta"
  for attempt in $(seq 1 30); do
    capture=$(tmux capture-pane -p -t "primary:fm-$id")
    case "$capture" in *AUTHENTICATED_WORKER_READY*) break ;; esac
    sleep 1
  done
  echo "WORKER PANE $n:"
  printf '%s\n' "$capture"
  case "$capture" in *AUTHENTICATED_WORKER_READY*) ;; *) echo 'Authenticated CLI readiness was not established'; exit 1 ;; esac
  if [ "$n" = 1 ]; then
    printf 'demo broken\ndemo 0\n' > "$FM_HOME/config/project-capacity"
    cp "$FM_HOME/config/project-capacity" "$FM_HOME/before-capacity"
  elif [ "$n" = 2 ]; then
    cmp "$FM_HOME/before-capacity" "$FM_HOME/config/project-capacity"
    printf 'demo 1\n' > "$FM_HOME/config/project-capacity"
    cp "$FM_HOME/config/project-capacity" "$FM_HOME/before-capacity"
  fi
done
cmp "$FM_HOME/before-capacity" "$FM_HOME/config/project-capacity"
echo 'REAL ENDPOINTS AT COMPLETION:'
tmux list-windows -t primary -F '#{window_name}: #{pane_current_command} #{pane_current_path}'
echo 'Three actual worker records and endpoints were admitted despite retired capacity 1; malformed retired configuration also admitted a worker and was preserved.'
touch "$FM_HOME/scenario-passed"
