#!/usr/bin/env bash
# Usage: fm-fastmode.sh [on|off|status]
# Defaults to status. The preference is a presence flag in the effective
# config directory (FM_CONFIG_OVERRIDE, FM_HOME, FM_ROOT_OVERRIDE, repo root).
set -euo pipefail

usage='Usage: fm-fastmode.sh [on|off|status]'
command=${1:-status}
case "$command" in
  -h|--help) printf '%s\n' "$usage"; exit 0 ;;
  on|off|status) [ "$#" -le 1 ] || { echo "$usage" >&2; exit 2; } ;;
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
