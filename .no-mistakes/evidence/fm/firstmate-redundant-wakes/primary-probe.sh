#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_TASK_ID
LAB=$(mktemp -d "$PWD/.XXX")
cleanup() {
  TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab kill-server 2>/dev/null || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bash bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmux"
touch "$LAB/config/supervision-host-off"
env -u NO_MISTAKES_GATE -u FM_GATE_REFUSE_BYPASS -u FM_ROOT_OVERRIDE -u FM_STATE_OVERRIDE -u FM_DATA_OVERRIDE -u FM_CONFIG_OVERRIDE -u FM_PROJECTS_OVERRIDE TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab new-session -d -s primary -x 120 -y 40 -c "$PWD" -e FM_HOME="$LAB" claude
sleep 8
TMUX_TMPDIR="$LAB/tmux" tmux -L fm-lab capture-pane -p -t primary
