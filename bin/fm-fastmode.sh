#!/usr/bin/env bash
# Usage: fm-fastmode.sh [on|off|status [codex-model]]
# Defaults to status. The optional model is the resolved Codex worker model.
# Status reports quota in the current environment; launch checks the worker
# environment separately. The preference is a presence flag in the effective
# config directory (FM_CONFIG_OVERRIDE, FM_HOME, FM_ROOT_OVERRIDE, repo root).
set -euo pipefail

usage='Usage: fm-fastmode.sh [on|off|status [codex-model]]'
command=${1:-status}
case "$command" in
  -h|--help) printf '%s\n' "$usage"; exit 0 ;;
  on|off) [ "$#" -eq 1 ] || { echo "$usage" >&2; exit 2; } ;;
  status) [ "$#" -le 2 ] || { echo "$usage" >&2; exit 2; } ;;
  *) echo "$usage" >&2; exit 2 ;;
esac

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG="${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-${SCRIPT_DIR%/bin}}}/config}"
preference="$CONFIG/worker-fast-mode"
case "$command" in
  on)
    mkdir -p -- "$CONFIG"
    if [ ! -e "$preference" ]; then
      (set -C; : > "$preference") || [ -e "$preference" ]
    fi
    ;;
  off) rm -f -- "$preference" ;;
esac
if [ -e "$preference" ]; then mode=on; else mode=off; fi
printf 'WORKER FAST MODE: %s\n' "$mode"

if [ "$command" = status ]; then
  model=${2:-}
  if [ "$mode" = off ]; then
    echo 'Next Codex worker: normal mode (fast mode is off).'
  elif [ -z "${model#model:}" ] || [ "${model#model:}" = default ]; then
    echo 'Next Codex worker: quota eligibility requires an explicit worker model.'
  else
    # shellcheck source=bin/fm-timeout-lib.sh
    . "$SCRIPT_DIR/fm-timeout-lib.sh"
    # shellcheck source=bin/fm-quota-axi-lib.sh
    . "$SCRIPT_DIR/fm-quota-axi-lib.sh"
    if fm_quota_codex_fast_probe "$model"; then
      printf 'Codex worker (%s): quota qualifies in this environment; launch rechecks in the worker environment.\n' "$model"
    else
      printf 'Codex worker (%s): quota eligibility could not be confirmed.\n' "$model"
    fi
  fi
fi
