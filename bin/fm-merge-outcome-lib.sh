#!/usr/bin/env bash
# Shared durable, supervisor-facing outcome publication for a confirmed merge.
#
# A synchronous self merge is already observed by its caller: commit the
# canonical notification marker without queueing another supervision turn.
# A poll observation publishes a durable local wake before committing that
# marker, so external merges and queued merges still wake exactly once in
# normal operation. A failed marker commit remains eligible for at-least-once
# retry, preferring a rare duplicate over a lost merge.
# Callers serialize their observation and marker commit with the task control
# lock; the marker lock also protects repeated publication of the same PR.
#
# Sourced by bin/fm-pr-merge.sh, bin/fm-watch.sh, and tests. No side effects on
# source beyond its sourced libraries.

_FM_MERGE_OUTCOME_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=bin/fm-pr-lib.sh
. "$_FM_MERGE_OUTCOME_LIB_DIR/fm-pr-lib.sh"

# shellcheck disable=SC2034 # Public result consumed by sourcing callers.
FM_MERGE_OUTCOME_ALREADY_RECORDED=false

# fm_merge_outcome_report <home> <state> <task-id> <pr-url> <origin> [authority]
#
# <origin> is self for a synchronous merge observed by its caller, or poll
# for an asynchronous observation requiring a durable wake.
# Optional <authority> supplies the persisted merge authority for poll rows.
# Attended rows remain untagged; away, external, and legacy tags are appended.
#
# Returns 0 when the outcome is acknowledged or published (or already was),
# 2 on an invalid request, and 1 on failure to record.
# A caller that has already merged must report a non-zero return rather
# than treat it as success: the merge landed and the record did not.
fm_merge_outcome_report() {  # <home> <state> <task-id> <pr-url> <origin> [authority]
  local home=$1 state=$2 id=$3 url=$4 origin=$5
  local authority=${6-} suffix=
  local lock status=0
  local provider host path number
  # shellcheck disable=SC2034 # Sourced wake helpers consume these scoped globals.
  local STATE FM_WAKE_QUEUE FM_WAKE_QUEUE_LOCK
  FM_MERGE_OUTCOME_ALREADY_RECORDED=false
  case "$origin" in self|poll) ;; *) return 2 ;; esac
  case "$authority" in
    away|external|yolo|away-grant) suffix=" $authority" ;;
    attended|'') ;;
    *) return 2 ;;
  esac
  fm_pr_task_id_valid "$id" || return 2
  fm_pr_url_parse "$url" || return 2
  provider=$FM_PR_PROVIDER
  host=$FM_PR_HOST
  path=$FM_PR_PATH
  number=$FM_PR_NUMBER
  [ -d "$state" ] && [ ! -L "$state" ] || return 1

  STATE=$state
  # shellcheck source=bin/fm-wake-lib.sh
  . "$_FM_MERGE_OUTCOME_LIB_DIR/fm-wake-lib.sh"
  lock="$state/$id.pr-poll-merge-notified.lock"
  fm_lock_acquire_wait "$lock" || return 1
  if fm_pr_poll_merge_already_notified "$state" "$id" \
    "$provider" "$host" "$path" "$number"; then
    # shellcheck disable=SC2034 # Public result consumed by sourcing callers.
    FM_MERGE_OUTCOME_ALREADY_RECORDED=true
    fm_lock_release "$lock"
    return 0
  fi

  if [ "$origin" = poll ]; then
    fm_wake_append check "merged-$id-$FM_PR_URL" \
      "check: merge landed: $id $FM_PR_URL$suffix" || status=1
  fi
  if [ "$status" -eq 0 ]; then
    fm_pr_poll_merge_mark_notified "$state" "$id" \
      "$provider" "$host" "$path" "$number" || status=1
  fi
  fm_lock_release "$lock"
  # Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
  [ ! -e "${FM_CONFIG_OVERRIDE:-$home/config}/fleet-ledger" ] || [ "$status" -ne 0 ] || FM_HOME=$home FM_STATE_OVERRIDE=$state "$_FM_MERGE_OUTCOME_LIB_DIR/fm-fleet-ledger.sh" merged "$id" pr "$FM_PR_URL" || true
  return "$status"
}
