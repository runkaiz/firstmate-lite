#!/usr/bin/env bash
# Read-only historical parent-channel identity helpers.
# Retained so archived outbound status is not mistaken for ordinary task work.
# This library publishes no messages and starts no supervisor agents.

_FM_PARENT_CHANNEL_LIB_DIR="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}" && pwd)"
# shellcheck source=bin/fm-secondmate-parent-lib.sh
. "$_FM_PARENT_CHANNEL_LIB_DIR/fm-secondmate-parent-lib.sh"

# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ID=
# shellcheck disable=SC2034 # Output globals read by sourcing callers.
FM_PARENT_CHANNEL_ROUTE=

# A mate id is used as a file-name component in the parent home, so it is
# accepted only when it is path-safe: no empty value, leading dot, slash, or
# character outside [A-Za-z0-9._-].
_fm_parent_channel_id_valid() {  # <id>
  local id=${1-}
  local LC_ALL=C
  case "$id" in
    ''|.*|*/*|*[!A-Za-z0-9._-]*) return 1 ;;
  esac
}

# The secondmate identity of <home>, printed, or non-zero for a main home (1)
# or an unusable identity marker (2).
fm_parent_channel_home_id() {  # <home>
  local home=$1 marker id
  marker="$home/.fm-secondmate-home"
  if [ ! -e "$marker" ] && [ ! -L "$marker" ]; then
    return 1
  fi
  [ -f "$marker" ] && [ ! -L "$marker" ] || return 2
  [ "$(wc -c < "$marker")" -eq "$(LC_ALL=C tr -d '\0' < "$marker" | wc -c)" ] || return 2
  id=$(cat "$marker" 2>/dev/null) || return 2
  _fm_parent_channel_id_valid "$id" || return 2
  printf '%s\n' "$id"
}

# Resolve the channel destination for <home> whose state dir is <state>.
# Prints the destination path and sets FM_PARENT_CHANNEL_ID and
# FM_PARENT_CHANNEL_ROUTE. Returns 1 for a main home, 2 for an unusable
# marker, 3 for a missing or unreadable parent binding.
fm_parent_channel_destination() {  # <home> <state>
  local home=$1 state=$2 id rc=0
  FM_PARENT_CHANNEL_ID=
  FM_PARENT_CHANNEL_ROUTE=
  id=$(fm_parent_channel_home_id "$home") || rc=$?
  [ "$rc" -eq 0 ] || return "$rc"
  fm_secondmate_parent_record_parse "$home/.fm-secondmate-parent" || return 3
  case "$FM_SECONDMATE_PARENT_ROUTE" in
    local)
      [ -n "$FM_SECONDMATE_PARENT_HOME" ] || return 3
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=local
      printf '%s/state/%s.status\n' "$FM_SECONDMATE_PARENT_HOME" "$id"
      ;;
    remote)
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ID=$id
      # shellcheck disable=SC2034 # Output globals read by sourcing callers.
      FM_PARENT_CHANNEL_ROUTE=remote
      printf '%s/parent-replies.status\n' "$state"
      ;;
    *) return 3 ;;
  esac
}

# The outbound parent-channel status path that lives INSIDE <state>, printed,
# when <home> is a remote mate; non-zero for a main home, a local mate, or an
# unusable identity or binding. Only the remote route resolves the channel into
# the mate's own state dir, so parent-replies.status there is the mate's parent
# channel rather than a self-home task status file: a home's own status scans
# and decision folds exclude exactly this resolved path (the same special case
# fm-pending-reply-lib.sh's wrong-home detection applies). A local mate's
# channel lives in the parent home's state/<id>.status, which the parent's
# scans must keep classifying, so only the remote route resolves here.
fm_parent_channel_outbound_status() {  # <home> <state>
  local home=$1 state=$2 destination rc=0
  destination=$(fm_parent_channel_destination "$home" "$state") || rc=$?
  [ "$rc" -eq 0 ] || return 1
  # The substitution above ran the resolver in a subshell, so its route global
  # died with it; resolve once more in this shell (stdout discarded, the same
  # shape fm-pending-reply-lib.sh's wrong-home detection uses) so the route
  # check reads the resolver's own verdict rather than re-deriving it.
  fm_parent_channel_destination "$home" "$state" >/dev/null || return 1
  [ "$FM_PARENT_CHANNEL_ROUTE" = remote ] || return 1
  printf '%s\n' "$destination"
}

# Fold <text> onto one bounded line, so a note copied from a child ledger or a
# hold reason cannot break the channel's line framing.


# Append <line> once, using fm-classify-lib.sh's retry contract. Time-insensitive:
# the caller declaring a new event is the one that stamps it.


# Publish one parent-facing line from <home>. See the return codes above.
