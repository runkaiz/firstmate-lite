#!/usr/bin/env bash
# Return reporting counts AI workers, including launching and unknown workers.
# Requires fm-backend.sh and fm-wake-lib.sh; sourcing has no side effects.
#
# Occupancy is conservative: every ordinary task record holds a slot unless
# fm-control exit recorded afk_worker_stopped=<spawn_gen> (legacy when absent)
# AND fresh backend evidence proves its agent dead or its exact Herdr pane gone.
# Completion, PRs, holds, idle turns and generic missing/unreadable states do not
# prove a stop. Reports, branches and arbitrary background jobs are untouched;
# this is not a limit on all background computation.
#
# The receipt lives in the task metadata and is bound to its incarnation.
# Control writes it under the control and metadata locks after verified exit.
# Relaunch takes the task-set lock, then
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
  case "$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)" in
    dead) return 0 ;;
    missing)
      # Herdr also maps a stopped server to missing. Only a fresh, exact pane
      # absence releases this receipt; counting must never start that server.
      [ "$backend" = herdr ] || return 1
      fm_backend_source herdr || return 1
      fm_backend_herdr_parse_target "$target" || return 1
      [ "$(fm_backend_herdr_pane_presence_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE" 2>/dev/null)" = dead ]
      ;;
    *) return 1 ;;
  esac
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

# Count the return brief's worker population.
fm_afk_capacity_count() {  # <state>
  local state=$1 meta
  FM_AFK_CAPACITY_COUNT=0
  for meta in "$state"/*.meta; do
    [ -f "$meta" ] || continue
    [ "$(fm_meta_get "$meta" kind)" != secondmate ] || continue
    fm_afk_capacity_released "$meta" && continue
    FM_AFK_CAPACITY_COUNT=$((FM_AFK_CAPACITY_COUNT + 1))
  done
}
