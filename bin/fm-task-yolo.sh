#!/usr/bin/env bash
# Re-record a live ship task's merge posture: the `yolo=` line in
# state/<task-id>.meta that bin/fm-spawn.sh wrote at dispatch.
#
# WHY. That line is this task's answer to "may firstmate land it without asking",
# and it is the one standing-authority record the away landing gate reads
# (bin/fm-merge-local.sh). It is frozen at dispatch, so a standing approval the
# captain gives afterwards, or a dispatch that recorded less than the captain's
# standing posture, otherwise lives only in prose the supervision session never
# reads: attended, main lands the work under the captain's word and nobody
# notices the stale record; away, the gate refuses and finished work waits for
# the return. This command is how main makes the record say what the captain
# said, in the same turn they say it.
#
# AUTHORITY. It writes a record; it approves nothing by itself. Main runs it
# only on the captain's own word covering this task (a standing approval, or a
# restriction), exactly as it chooses --yolo at dispatch (AGENTS.md section 7),
# and notes those words on the backlog item.
#   - The supervision branch is refused in every posture, away included: the
#     session that acts on a merge posture never writes one.
#   - `on` is refused for every actor while an away record exists, because
#     merge authority grows only while the captain is present. `off` only
#     restricts, so it is accepted in any posture.
#   - Only a ship task with a recorded mode and exactly one yolo= line is
#     accepted; a scout or secondmate record has no merge posture to change.
# The task's control lock serializes the change with a landing in progress, and
# the away-record lock spans the posture read and the write, so entering away
# cannot race a grant.
#
# Usage: fm-task-yolo.sh <task-id> <on|off>
# Prints "recorded <task-id> yolo=<value> (was <old>)", or "unchanged" when the
# record already says so. Exit 0 recorded or unchanged, 1 refused, 2 usage.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

if [ "$#" -ne 2 ] || ! fm_pr_task_id_valid "$1"; then
  echo "usage: fm-task-yolo.sh <task-id> <on|off>" >&2
  exit 2
fi
ID=$1
VALUE=$2
case "$VALUE" in
  on|off) ;;
  *) echo "error: the merge posture must be on or off (got '$VALUE')" >&2; exit 2 ;;
esac

# Role partition: never relocated. The branch acts on this record and so never
# writes it, whatever the posture (contract: bin/fm-lease-lib.sh).
fm_lease_forbid_branch "task merge posture change (fm-task-yolo)"

META="$STATE/$ID.meta"
[ -f "$META" ] && [ ! -L "$META" ] || { echo "error: no task record for $ID at $META" >&2; exit 1; }

CONTROL_LOCK=
META_LOCK=
META_TMP=
posture_cleanup() {
  [ -z "$META_TMP" ] || rm -f -- "$META_TMP"
  fm_afk_contract_lock_release || true
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK" || true
  [ -z "$CONTROL_LOCK" ] || fm_lock_release "$CONTROL_LOCK" || true
}
trap posture_cleanup EXIT
trap 'exit 1' HUP INT TERM

CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$CONTROL_LOCK"
META_LOCK=$(fm_meta_lock_path "$META") || { echo "error: no lock path for $META" >&2; exit 1; }
fm_lock_acquire_wait "$META_LOCK"

[ -f "$META" ] && [ ! -L "$META" ] && [ "$(fm_pr_file_link_count "$META")" = 1 ] \
  || { echo "error: task record for $ID is unavailable" >&2; exit 1; }
KIND=$(awk '/^kind=/{n++; value=substr($0,6)} END{if(n==1) print value}' "$META")
MODE=$(awk '/^mode=/{n++; value=substr($0,6)} END{if(n==1) print value}' "$META")
OLD=$(awk '/^yolo=/{n++; value=substr($0,6)} END{if(n==1) print value}' "$META")
[ "$KIND" = ship ] || { echo "error: $ID is not a ship task; only a ship task records a merge posture" >&2; exit 1; }
case "$MODE" in
  no-mistakes|direct-PR|local-only) ;;
  *) echo "error: $ID records no ship delivery mode; refusing to change its merge posture" >&2; exit 1 ;;
esac
case "$OLD" in
  on|off) ;;
  *) echo "error: $ID does not record exactly one yolo=on or yolo=off line; refusing to guess its merge posture" >&2; exit 1 ;;
esac

fm_afk_contract_lock_hold "$STATE" || {
  echo "error: merge posture change refused: away-posture record could not be locked" >&2
  exit 1
}
if [ "$VALUE" = on ] && fm_afk_contract_present "$STATE"; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" validate >/dev/null || {
    echo "error: merge posture change refused: unreadable away-posture record" >&2
    exit 1
  }
  if fm_afk_contract_away_present "$STATE"; then
    echo "error: merge posture change refused - an away record exists, and a task's merge authority grows only while the captain is present; $ID stays yolo=$OLD until their return" >&2
    exit 1
  fi
fi

if [ "$OLD" = "$VALUE" ]; then
  echo "unchanged $ID yolo=$VALUE"
  exit 0
fi

META_TMP=$(mktemp "$STATE/.fm-task-yolo.XXXXXX") || exit 1
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in
    yolo=*) printf 'yolo=%s\n' "$VALUE" >> "$META_TMP" || exit 1 ;;
    *) printf '%s\n' "$line" >> "$META_TMP" || exit 1 ;;
  esac
done < "$META"
[ "$(awk '/^yolo=/{n++; value=substr($0,6)} END{if(n==1) print value}' "$META_TMP")" = "$VALUE" ] \
  || { echo "error: could not prepare the new task record for $ID" >&2; exit 1; }
chmod 0600 "$META_TMP" || exit 1
mv -f -- "$META_TMP" "$META" || exit 1
META_TMP=

echo "recorded $ID yolo=$VALUE (was $OLD)"
echo "next: note the captain's words behind this change on the backlog item for $ID" >&2
