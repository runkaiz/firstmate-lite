#!/usr/bin/env bash
# fm-queue.sh - native queue addressed to this operational home.
# Usage: fm-queue.sh [<command> [args...]]
# Run `fm-queue.sh <command> --help` for the shipped storage interface.
# FM_DATA_OVERRIDE, then FM_HOME/data, then the code-root data select the queue.
# The existing addressing/transition library owns path and symlink refusals.
# Relative --to, --backup-dir and --*-file values resolve from the caller directory;
# report links remain relative to the backlog root. Caller --file is refused.
# add/create --start is refused: fm-spawn owns worker bindings and dispatch.
# show/view/list decode hold reasons through fm-hold-reason-lib.sh.
# Body history, archived identity and transaction recovery belong to fm-queue.py.
# fm-tasks-axi.sh is a deprecated alias, not an external executable dependency.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-hold-reason-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-hold-reason-lib.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

fail() {
  printf 'fm-queue: %s\n' "$*" >&2
  exit 2
}

case "${1:-}" in
  -h|--help)
    usage
    exit 0
    ;;
esac

CALLER_DIR=$(pwd)

absolute_from_caller() {  # <path-value>
  case "$1" in
    ''|-|/*) printf '%s' "$1" ;;
    *) printf '%s/%s' "$CALLER_DIR" "$1" ;;
  esac
}

ARGS=()
path_value_next=0
for arg in "$@"; do
  if [ "$path_value_next" = 1 ]; then
    ARGS+=("$(absolute_from_caller "$arg")")
    path_value_next=0
    continue
  fi
  case "$arg" in
    --file|--file=*)
      fail "this command always addresses this home's backlog at $DATA; drop --file, or use bin/fm-queue.py --file for an explicitly selected separate backlog"
      ;;
    --start)
      case "${1:-}" in
        add|create)
          fail "add --start would place a row In flight with no dispatch record; add it Queued and let bin/fm-spawn.sh start it"
          ;;
      esac
      ARGS+=("$arg")
      ;;
    --to|--backup-dir|--*-file)
      ARGS+=("$arg")
      path_value_next=1
      ;;
    --to=*|--backup-dir=*|--*-file=*)
      ARGS+=("${arg%%=*}=$(absolute_from_caller "${arg#*=}")")
      ;;
    *)
      ARGS+=("$arg")
      ;;
  esac
done

fm_tasks_axi_compatible || fail "native queue requires python3 and the shipped bin/fm-queue.py"

FM_BACKLOG_TRANSITION_ERROR=
if ! fm_backlog_tasks_axi_addressing "$DATA" ${ARGS[@]+"${ARGS[@]}"}; then
  fail "${FM_BACKLOG_TRANSITION_ERROR:-data directory cannot be resolved: $DATA}"
fi

if [ -n "$FM_BACKLOG_AXI_FILE" ]; then
  if [ -L "$FM_BACKLOG_AXI_FILE" ]; then
    fail "$FM_BACKLOG_AXI_FILE is a symlink; native writes replace files atomically - make it this home's real file to avoid forking the backlog"
  fi
  export FM_QUEUE_FILE="$FM_BACKLOG_AXI_FILE"
  unset TASKS_AXI_FILE
else
  unset TASKS_AXI_FILE FM_QUEUE_FILE
fi

cd "$FM_BACKLOG_AXI_ROOT" || fail "cannot enter the backlog root $FM_BACKLOG_AXI_ROOT"
case "${1:-}" in
  show|view|list)
    set -o pipefail
    "$FM_QUEUE_CLI" ${ARGS[@]+"${ARGS[@]}"} | fm_hold_reason_decode_stream
    exit $?
    ;;
esac
exec "$FM_QUEUE_CLI" ${ARGS[@]+"${ARGS[@]}"}
