#!/usr/bin/env bash
# AFK admission counts AI workers, including launching and unknown workers.
# Requires fm-backend.sh and fm-wake-lib.sh; sourcing has no side effects.
#
# Occupancy is conservative: every ordinary task record holds a slot unless
# fm-control exit recorded afk_worker_stopped=<spawn_gen> (legacy when absent)
# AND the recovery-grade backend classifier still proves its agent dead.
# Completion, PRs, holds, idle turns and missing/unreadable endpoints do not
# prove a stop. Reports, branches and arbitrary background jobs are untouched;
# this is not a limit on all background computation.
#
# The receipt lives in the task metadata and is bound to its incarnation.
# Control writes it under the control and metadata locks after verified exit.
# Relaunch takes the task-set lock, admits against the other workers, then
# consumes the receipt under the metadata lock before launching. Failure after
# consumption conservatively retains occupancy until another verified exit.
# Fresh spawn holds that same task-set lock through metadata publication.
# Supported typed steering refuses a stopped receipt: only lifecycle relaunch
# may reactivate it. Inbox enqueue is still allowed, without ringing it.
# Late observable agent activity invalidates the exclusion at the next count.
# Unknown, stale, malformed or unsupported evidence never releases a slot.

fm_afk_capacity_generation() {  # <meta>
  local gen
  gen=$(fm_meta_get "$1" spawn_gen)
  printf '%s' "${gen:-legacy}"
}

fm_afk_capacity_released() {  # <meta>
  local meta=$1 id backend target
  [ -r "$meta" ] && [ ! -L "$meta" ] || return 1
  [ "$(fm_meta_get "$meta" afk_worker_stopped)" = "$(fm_afk_capacity_generation "$meta")" ] || return 1
  id=${meta##*/}; id=${id%.meta}
  fm_backend_validate_task_endpoint "$meta" "$id" >/dev/null 2>&1 || return 1
  backend=$FM_BACKEND_VALIDATED_BACKEND
  target=$FM_BACKEND_VALIDATED_TARGET
  [ "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)" = dead ]
}

# Caller holds the metadata lock (and control lock when stopping, or task-set
# lock when reserving). Preserve every other field, including PRs and holds.
fm_afk_capacity_receipt_write() {  # <meta> <stopped|reserved>
  local meta=$1 action=$2 tmp
  [ -f "$meta" ] && [ ! -L "$meta" ] || return 1
  tmp=$(mktemp "${meta}.afk.XXXXXX") || return 1
  if ! awk '!/^afk_worker_stopped=/' "$meta" > "$tmp"; then
    rm -f "$tmp"; return 1
  fi
  if [ "$action" = stopped ]; then
    printf 'afk_worker_stopped=%s\n' "$(fm_afk_capacity_generation "$meta")" >> "$tmp" || {
      rm -f "$tmp"; return 1
    }
  fi
  # Replacement metadata remains private.
  if ! chmod 600 "$tmp" || ! mv -f "$tmp" "$meta"; then
    rm -f "$tmp"; return 1
  fi
}

fm_afk_capacity_record_stop() {  # <meta>; caller holds control lock
  local lock rc=0
  lock=$(fm_meta_lock_path "$1") || return 1
  fm_lock_try_acquire "$lock" || return 1
  fm_afk_capacity_receipt_write "$1" stopped || rc=1
  fm_lock_release "$lock"
  return "$rc"
}

# Outputs count + holder ids. With no exclusion this is also the reporting
# population; a relaunch excludes its own already-reserved/released record.
fm_afk_capacity_count() {  # <state> [exclude-id]
  local state=$1 exclude=${2:-} meta id
  FM_AFK_CAPACITY_COUNT=0
  FM_AFK_CAPACITY_HOLDERS=
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    id=${meta##*/}; id=${id%.meta}
    [ "$id" != "$exclude" ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    fm_afk_capacity_released "$meta" && continue
    FM_AFK_CAPACITY_COUNT=$((FM_AFK_CAPACITY_COUNT + 1))
    FM_AFK_CAPACITY_HOLDERS="${FM_AFK_CAPACITY_HOLDERS:+$FM_AFK_CAPACITY_HOLDERS, }$id"
  done
}

fm_afk_capacity_check() {  # <state> <task-id> <fresh|relaunch>
  local state=$1 id=$2 action=$3 cap exclude=
  [ -f "$state/.afk-contract" ] || return 0
  FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-afk-contract.sh" validate >/dev/null 2>&1 || return 0
  [ "$(FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-afk-contract.sh" mode 2>/dev/null)" = away ] || return 0
  cap=$(FM_STATE_OVERRIDE="$state" "$SCRIPT_DIR/fm-afk-contract.sh" field spend_max_concurrent_workers 2>/dev/null || true)
  case "$cap" in ''|*[!0-9]*|0) return 0 ;; esac
  [ "$action" != relaunch ] || exclude=$id
  fm_afk_capacity_count "$state" "$exclude"
  if [ "$FM_AFK_CAPACITY_COUNT" -ge "$cap" ]; then
    echo "error: spawn refused - the away-posture record caps concurrent workers at $cap; $FM_AFK_CAPACITY_COUNT AI worker slot(s) are occupied or unconfirmed ($FM_AFK_CAPACITY_HOLDERS). Task $id stays queued or stopped. Completion alone does not release a slot: use fm-control exit to confirm a worker stopped; preserved reports and work need no cleanup." >&2
    return 1
  fi
}
