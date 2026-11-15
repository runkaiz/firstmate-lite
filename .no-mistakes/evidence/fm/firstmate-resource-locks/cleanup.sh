#!/usr/bin/env bash
set -eu
repo_root=/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ
exec > /home/runkai/.no-mistakes/evidence/01M7E5G3VE4WRF2AH7TSMB9MDJ/lab-cleanup.log 2>&1
export FM_HOME="$repo_root/l"
export TMPDIR="$FM_HOME/tmp"
unset FM_ROOT_OVERRIDE FM_CONFIG_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS
while read -r id; do
  echo "Removing disposable task $id through fm-teardown.sh"
  FM_TEARDOWN_GUARD_DONE=1 "$repo_root/bin/fm-teardown.sh" "$id"
done < "$FM_HOME/ids"
touch "$FM_HOME/cleanup-passed"
