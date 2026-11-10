#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE FM_GATE_REFUSE_BYPASS FM_SUPERVISION_ACTOR
export FM_HOME="$ROOT/.gate-test-lab/counterfactual"
export TMPDIR="$ROOT/.gate-test-lab/tmp"
export TMUX="$ROOT/.gate-test-lab/absent-socket,0,0"
trap 'rm -rf -- "$FM_HOME"' EXIT
"$ROOT/bin/fm-lab-home.sh" create "$FM_HOME"
printf 'manual\n' > "$FM_HOME/config/backlog-backend"
printf 'off\n' > "$FM_HOME/config/usage-ledger"
PROJ="$FM_HOME/projects/demo"
mkdir -p "$PROJ"
git -C "$PROJ" init -q -b main
git -C "$PROJ" -c user.name=lab -c user.email=lab@example.invalid commit -qm initial --allow-empty
BASE=$(git -C "$PROJ" rev-parse HEAD)
git -C "$PROJ" switch -qc fm/kept
printf 'retained result\n' > "$PROJ/result.txt"
git -C "$PROJ" add result.txt
git -C "$PROJ" -c user.name=lab -c user.email=lab@example.invalid commit -qm task
TIP=$(git -C "$PROJ" rev-parse HEAD)
git -C "$PROJ" switch -q main
# Persisted public retained-record contract, representing a completed cleanup.
printf 'project=%s\nmode=local-only\nbranch=fm/kept\n' "$PROJ" > "$FM_HOME/state/kept.retained"
printf 'BASE d3c6453: attempt the retained landing with no task metadata\n'
if bash "$ROOT/.gate-test-lab/baseline/bin/fm-merge-local.sh" kept > "$FM_HOME/base.out" 2>&1; then
  echo 'ERROR: the base unexpectedly accepted the scenario'; exit 1
fi
cat "$FM_HOME/base.out"
grep -Fq 'no meta for task kept' "$FM_HOME/base.out"
[ "$(git -C "$PROJ" rev-parse main)" = "$BASE" ]
printf '\nTARGET 6ecfe0f: retry the exact same persisted state\n'
"$ROOT/bin/fm-merge-local.sh" kept
[ "$(git -C "$PROJ" rev-parse main)" = "$TIP" ]
[ ! -e "$FM_HOME/state/kept.retained" ]
cat "$PROJ/result.txt"
printf 'Observed: base refused the missing task record; target landed the same retained commit and retired its landing record.\n'
