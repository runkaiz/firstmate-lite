#!/usr/bin/env bash
# Home-scoped proactive preference and instruction rendering.
# Usage: fm-proactive.sh [toggle|on|off|status|instructions|context]
# No argument toggles. status reads without writing; instructions prints the
# current mode plus its policy when on. context prints only the current mode
# and a policy reference for wake tails. Only exact on/off (with an optional
# final newline) are accepted. Missing means off; malformed/unreadable means
# off with a diagnostic, and toggle refuses to overwrite it (explicit on/off
# repairs it). Writes replace the preference atomically; failure is nonzero.
# Path precedence matches Calm: FM_CONFIG_OVERRIDE, otherwise config under
# FM_HOME, FM_ROOT_OVERRIDE, or this script's tracked root, in that order.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
CONFIG="${FM_CONFIG_OVERRIDE:-${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}/config}"
PREFERENCE="$CONFIG/proactive"
MODE=off
INVALID=0

read_preference() {
  local stored
  if [ ! -e "$PREFERENCE" ] && [ ! -L "$PREFERENCE" ]; then return; fi
  # Appending a sentinel preserves extra trailing newlines for validation.
  if [ ! -f "$PREFERENCE" ] || ! stored=$(cat "$PREFERENCE" && printf '.'); then
    INVALID=1
  else
    case "$stored" in
      on.|$'on\n.') MODE=on ;;
      off.|$'off\n.') MODE=off ;;
      *) INVALID=1 ;;
    esac
    # Bash strips NUL bytes in command substitution; exact-byte comparison
    # prevents such malformed files from becoming an apparent valid value.
    cmp -s "$PREFERENCE" <(printf '%s' "${stored%.}") || INVALID=1
  fi
  if [ "$INVALID" -eq 1 ]; then
    MODE=off
    printf 'proactive: invalid or unreadable preference at %s; using off; repair with explicit on or off.\n' "$PREFERENCE" >&2
  fi
}

write_preference() {
  local temporary
  [ ! -d "$PREFERENCE" ] || { echo 'proactive: preference is a directory; choice unchanged.' >&2; return 1; }
  mkdir -p "$CONFIG"
  # Reuse the portable lock owner; loading it only on writes keeps status pure.
  # shellcheck source=bin/fm-wake-lib.sh
  . "$SCRIPT_DIR/fm-wake-lib.sh"
  fm_lock_acquire_wait "$CONFIG/.proactive.lock"
  trap 'fm_lock_release "$CONFIG/.proactive.lock"' EXIT
  if [ "$1" = toggle ]; then
    MODE=off INVALID=0
    read_preference
    [ "$INVALID" -eq 0 ] || return 1
    if [ "$MODE" = on ]; then set -- off; else set -- on; fi
  fi
  temporary=$(mktemp "$CONFIG/.proactive.XXXXXX")
  if ! printf '%s\n' "$1" > "$temporary" || ! mv -f -- "$temporary" "$PREFERENCE"; then
    rm -f -- "$temporary"
    printf 'proactive: could not persist preference; choice unchanged.\n' >&2
    return 1
  fi
  MODE=$1
}

command=${1:-toggle}
[ "$#" -le 1 ] || { echo 'usage: fm-proactive.sh [toggle|on|off|status|instructions|context]' >&2; exit 2; }
case "$command" in
  --help|-h) sed -n '2,12p' "${BASH_SOURCE[0]}"; exit 0 ;;
  toggle|on|off|status|instructions|context) ;;
  *) echo 'usage: fm-proactive.sh [toggle|on|off|status|instructions|context]' >&2; exit 2 ;;
esac
read_preference
case "$command" in
  toggle)
    [ "$INVALID" -eq 0 ] || exit 1
    write_preference toggle
    ;;
  on|off) write_preference "$command" ;;
esac
printf 'PROACTIVE MODE: %s\n' "$MODE"
if [ "$command" = instructions ] || [ "$command" = context ]; then
  if [ "$MODE" = on ]; then
    if [ "$command" = instructions ]; then
      cat "$ROOT/.agents/skills/proactive/policy.md"
    else
      printf 'Apply %s; load it only if absent from current context, otherwise reuse it. Existing role/posture limits still apply.\n' "$ROOT/.agents/skills/proactive/policy.md"
    fi
  else
    printf '%s\n' 'Use baseline orchestration; any earlier proactive instruction is inactive.'
  fi
fi
