#!/usr/bin/env bash
source .test-live/common-worker.sh
case_home worker
printf 'harness=codex\n' >> "$FM_HOME/state/$ID.meta"
printf 'active edit\n' > "$WT/draft"
tmux -L fm-lab new-window -d -t fm-lab -n "fm-$ID" -c "$ROOT" -e "FM_HOME=$FM_HOME" 'env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE codex'
sleep 3
step tmux -L fm-lab display-message -p -t "fm-lab:fm-$ID" '#{pane_width}x#{pane_height} #{pane_current_command}'
step tmux -L fm-lab capture-pane -p -t "fm-lab:fm-$ID"
before=$(fingerprint)
out=$(bash bin/fm-reconcile-underway.sh)
printf '%s\n' "$out"
check test "$(printf '%s\n' "$out" | cut -f2)" = ongoing
check test "$(printf '%s\n' "$out" | cut -f3)" = -
check test "$(fingerprint)" = "$before"
tmux -L fm-lab kill-window -t "fm-lab:fm-$ID"
sed -i 's/^kind=ship$/kind=scout/;/^mode=/d' "$FM_HOME/state/$ID.meta"
out=$(bash bin/fm-reconcile-underway.sh)
printf '%s\n' "$out"
check test "$(printf '%s\n' "$out" | cut -f2)" = ongoing
check test "$(printf '%s\n' "$out" | cut -f3)" = 'bin/fm-control.sh worker relaunch'
echo 'SCENARIO PASS: real Codex worker stays ongoing; missing worker with unfinished report gets guarded relaunch advice'
