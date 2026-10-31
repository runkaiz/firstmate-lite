#!/usr/bin/env bash
source .test-live/common-extra.sh
export FM_HERDR_LAB_STATE_DIR="$ROOT/.test-live/herdr-state"
lab=fm-lab-stow-gate
old_cleanup=$(declare -f cleanup)
eval "${old_cleanup/cleanup ()/common_cleanup ()}"
cleanup() {
  bash "$ROOT/bin/fm-herdr-lab.sh" teardown "$lab"
  common_cleanup
}
trap cleanup EXIT
case_home herdr-preserve
out=$(bash bin/fm-herdr-lab.sh run "$lab" workspace create --cwd "$WT" --label stow-cleanup --no-focus)
printf '%s\n' "$out"
printf '%s' "$out" > "$CASE/workspace.json"
bash bin/fm-herdr-lab.sh run "$lab" pane list
echo "HOME_FOR_NEXT=$FM_HOME"
echo "COPY_FOR_NEXT=$WT"
echo "CASE_FOR_NEXT=$CASE"
source "$ROOT/.test-live/herdr-next.sh"
