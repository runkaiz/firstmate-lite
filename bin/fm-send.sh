#!/usr/bin/env bash
# Steer a recorded ship/scout task through its durable instruction inbox.
# Usage: fm-send.sh <target> [--resolve-key <key>]... <text...>
#        fm-send.sh <target> --key Enter
# <target> is an exact task id, a legacy fm-<id> label resolved through this
# home's metadata, or an explicit well-formed backend endpoint.
# FM_HOME must be explicit so a steer cannot silently address another home.
# Retired persistent supervisor records and remote supervisor targets refuse.
# Empty and whitespace-only messages refuse before recording or typing.
#
# INBOX: ordinary text to a recorded task is a durable sequenced record under
# state/<id>.inbox/. Newlines are legal. Only the constant self-describing
# doorbell is typed, best-effort; a pending composer skips that ring.
# A successful enqueue is delivery even if the ring fails. The worker's move
# into handled/ acknowledges reading; bin/fm-task-inbox-lib.sh owns the format
# and the watcher's re-ring/escalation policy. A repeat send is a NEW record.
# A failed enqueue is loud and never claims delivery.
#
# TYPED: leading slash invocations, a leading dollar sign for Codex, and explicit
# backend endpoints reach the harness parser through its verified submit core.
# Text is typed once and Enter may be retried; exit 0 confirms submission,
# exit 3 means typed but unconfirmed (inspect before retrying, never blindly
# retype), and any other nonzero means no delivery may be assumed.
# FM_SEND_RETRIES defaults to 3 (20 for agy), FM_SEND_SLEEP to 0.4 seconds.
# Parser-native invocations receive the existing pre-Enter settle.
# Key support is backend-specific: tmux/herdr accept Escape, Enter, and C-c;
# Orca accepts Enter and C-c and refuses Escape.
#
# Decision closure (answerer-closes): pass --resolve-key <key> (repeatable,
# before the message) when this send answers an open keyed needs-decision: or
# blocked: record in the target task's state/<id>.status. fm-send itself
# appends the closing resolved line to that status file, so the captain-facing
# OPEN DECISIONS record closes at answer time and never depends on the busy
# worker writing a matching resolved line. For ordinary keys the payload is
# "resolved [key=<key>]: answered: <capped excerpt>" before the emission-time
# handling owned by bin/fm-classify-lib.sh. A reserved key
# (pending-reply-* today; bin/fm-classify-lib.sh's reserved-key guard) is
# closed with the owning library's vocabulary note
# (the explicit historical formatter in fm_send_resolve_close_note), so
# the fold actually drops it; a bare answered: note is not a reserved-key
# transition and is never written for those keys. If this send cannot produce
# a note the guard will accept, or the structural key would be lost to the
# status-line cap, it refuses before sending and names the cause rather than
# exiting 0 on a silent no-op. After a delivered close it also
# re-folds and fails loudly if the named key is still open. On the inbox plane
# the close happens at ENQUEUE time, because enqueue is durable delivery to
# the task's record; the worker reading the answer late is covered by the
# acknowledgement re-ring ladder. On the typed plane it still waits for the
# confirmed submit. The close is a LOCAL append for every target kind -
# crewmate or scout - because the open-decision ledger lives in this home.
#
# Answering a decision is the gate-answer path and is main-owned while
# attended: when any named key is an open needs-decision or a captain-held task
# (a blocked: key is ordinary steering and stays lease-guarded only), the Pi
# supervision branch is refused outright, exactly as its prompt promises. While
# the away-posture record exists main is parked and that one refusal relocates
# to the branch (contract: bin/fm-lease-lib.sh); which findings firstmate may
# decide at all remains ask-user-authority's judgment for either actor.
#
# Chat is also a channel that carries keyed captain answers, so the same flag
# feeds bin/fm-captain-hold.sh's one keyed-answer intake for any key that names
# a captain-held task in this home - the key as a task id itself, or through
# the legacy `<task>-decision-<key>` identity for pre-collapse rows. fm-send
# closes nothing itself; it hands the intake `<task-id>\t<answer>\t<label>`
# exactly as every other channel does, and the intake owns what that means.
# This is what lets an answer reach a decision that has already been
# transferred from the live status log to its durable captain-held task, which
# the status ledger alone can no longer close.
#
# Each named key must therefore currently be open in ONE of the two ledgers: open
# in this home's status log per status_open_decisions (bin/fm-classify-lib.sh), or
# a still-open captain-held task resolved as above. A key in neither is refused
# before sending, so a mistyped key cannot deliver an answer while silently
# orphaning the decision. A failed or unconfirmed send never closes a key; a
# delivered answer whose closing append fails exits nonzero with the exact
# manual close command, leaving the decision open to re-surface (the safe
# direction). A send without the flag never closes anything: a routine steer,
# working:, or done: event still cannot clear a captain decision. The flag is
# refused with --key, with an explicit backend target (no task ledger in this
# home), and with an empty message.
#
# After a successful TYPED-plane submit fm-send pauses FM_SEND_SETTLE seconds
# (default 1, 0 disables) before returning: submit confirmation only proves the
# text was accepted, but the harness needs a beat to spin up the turn before its
# busy footer appears, so an immediate peek would otherwise see the stale idle
# pane. The pause is typed-plane-only; the inbox plane, the shared submit core
# (used by the away-mode daemon, which only needs "submitted"), and the --key
# path do not pay it.
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"

# shellcheck source=bin/fm-gate-refuse-lib.sh
. "$SCRIPT_DIR/fm-gate-refuse-lib.sh"
# Fail closed before any fleet mutation: a no-mistakes gate agent must never steer
# a crewmate (see bin/fm-gate-refuse-lib.sh).
fm_refuse_if_gate_agent

if [ -z "${FM_HOME+x}" ] || [ -z "${FM_HOME:-}" ]; then
  echo "error: FM_HOME is not set; fm-send refuses to resolve targets without an explicit firstmate home" >&2
  # Name the remedy, never apply it: a guessed home could act on another home's task.
  printf 'next: name the home explicitly; for the home at this code root that is:\n  FM_HOME=%q %q' "$FM_ROOT" "$SCRIPT_DIR/fm-send.sh" >&2
  [ "$#" = 0 ] || printf ' %q' "$@" >&2
  printf '\n' >&2
  exit 1
fi

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
if [ ! -d "$FM_HOME" ]; then
  echo "error: FM_HOME '$FM_HOME' is not a directory; fm-send cannot resolve this home's state" >&2
  exit 1
fi
if [ ! -d "$STATE" ]; then
  echo "error: state dir '$STATE' is missing; fm-send cannot resolve targets for FM_HOME '$FM_HOME'" >&2
  exit 1
fi

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-control-lib.sh
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-marker-lib.sh
. "$SCRIPT_DIR/fm-marker-lib.sh"
# shellcheck source=bin/fm-classify-lib.sh
. "$SCRIPT_DIR/fm-classify-lib.sh"
# shellcheck source=bin/fm-line-cap-lib.sh
. "$SCRIPT_DIR/fm-line-cap-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-task-inbox-lib.sh
. "$SCRIPT_DIR/fm-task-inbox-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FM_GUARD_CONTINUE_LINE='This is a supervision warning only; the requested message WILL still be sent.' "$SCRIPT_DIR/fm-guard.sh" || true

fm_send_id_from_meta() { # <meta-file>
  local base
  base=${1##*/}
  printf '%s' "${base%.meta}"
}

# fm_send_clear_after_interrupt: muse RESTORES the interrupted prompt back into
# the composer when Escape cancels a turn, as real bright text (verified: fg
# 38;2;204;211;219, luminance ~210, muse 0.1.0-R708.1), not de-emphasised ghost
# text. Classifying that as pending input is correct - the text really is
# unsubmitted - but leaving it there means the NEXT steer types onto the end of
# it and submits both as one garbled message. Ctrl-U clears the composer
# (verified), so the interrupt is not complete until it has been sent. A failed
# clear is loud rather than silent, because the alternative is a corrupted steer.
# WHICH adapters need that clear, and which key clears them, comes from the one
# control-plane capability table (bin/fm-control-lib.sh) rather than a second
# copy here - the same table bin/fm-control.sh's interrupt verb reads.
fm_send_clear_after_interrupt() { # <key>
  local key=$1 family clear
  [ "$key" = Escape ] || return 0
  family=$(fm_control_harness_family "$TARGET_HARNESS") || return 0
  clear=$(fm_control_interrupt_clear_key "$family") || return 0
  [ -n "$clear" ] || return 0
  [ "$TARGET_BACKEND" != remote ] || return 0
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$clear" "$EXPECTED_LABEL"; then
    echo "error: Escape reached $T, but the $TARGET_HARNESS composer could not be cleared; it still holds the restored prompt. Clear it before sending the next message." >&2
    return 1
  fi
}

fm_send_normalize_key() { # <key>
  case "$1" in
  Escape | escape | Esc | esc) printf '%s' Escape ;;
  *) printf '%s' "$1" ;;
  esac
}

fm_send_record_interrupt() { # <key>
  local key=$1 id gen
  [ "$key" = Escape ] || return 0
  case "$TARGET_HARNESS" in claude*) : ;; *) return 0 ;; esac
  [ -n "$TARGET_META" ] || return 0
  id=$(fm_send_id_from_meta "$TARGET_META")
  [ -f "$STATE/$id.busy-gen" ] || return 0
  gen=$(fm_meta_get "$TARGET_META" busy_gen)
  if [ -n "$gen" ]; then
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --gen "$gen" --source fm-interrupt --event interrupt
  else
    "$FM_ROOT/bin/fm-busy-event.sh" apply "$STATE" "$id" idle \
      --current-gen --source fm-interrupt --event interrupt
  fi || {
    echo "error: key '$key' reached $T, but the Claude interrupt state could not be recorded for $id" >&2
    return 1
  }
}

fm_send_meta_for_key_value() { # <state-dir> <key> <value>
  local state=$1 key=$2 value=$3 meta got
  for meta in "$state"/*.meta; do
    [ -e "$meta" ] || continue
    got=$(fm_meta_get "$meta" "$key")
    [ "$got" = "$value" ] || continue
    printf '%s' "$meta"
    return 0
  done
  return 1
}

fm_send_count_colons() { # <string>
  local s=$1 no_colons
  no_colons=${s//:/}
  printf '%s' $((${#s} - ${#no_colons}))
}

fm_send_resolve_target() { # <raw-target>
  local raw=$1 meta pane_meta target backend assumed colons id session hint

  RESOLVED_TARGET=""
  TARGET_BACKEND=""
  TARGET_HARNESS=""
  EXPECTED_LABEL=""
  TARGET_META=""
  TARGET_SELECTOR=""
  RESOLUTION_TRIED=""

  meta=$(fm_backend_meta_for_selector "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    if [ "$(fm_meta_get "$meta" kind)" = secondmate ]; then
      echo "error: persistent supervisor targets are unsupported; private metadata and endpoints are preserved" >&2
      return 1
    fi
    if [ -n "$(fm_meta_get "$meta" remote_host)" ]; then
      echo "error: persistent remote supervisor targets are unsupported; use fm-on.sh with an explicit remote route for tracked commands" >&2
      return 1
    fi
    RESOLUTION_TRIED="meta=$meta; backend=from-meta"
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried $RESOLUTION_TRIED)" >&2
      return 1
    fi
    backend=$(fm_backend_of_meta "$meta")
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$backend
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    EXPECTED_LABEL=$(fm_backend_expected_label_of_selector "$raw" "$STATE")
    TARGET_SELECTOR=1
    return 0
  fi

  case "$raw" in
  fm-*:*)
    # A named Herdr session may itself begin with "fm-". Keep that explicit
    # session:pane target on the validated backend-target path below rather
    # than mistaking it for an unresolved task selector.
    ;;
  fm-*)
    RESOLUTION_TRIED="meta=$STATE/$raw.meta; legacy-meta=$STATE/${raw#fm-}.meta; backend=none"
    echo "error: no metadata for $raw in $STATE (tried $RESOLUTION_TRIED); pass a well-formed explicit backend target only when targeting outside this firstmate home" >&2
    return 1
    ;;
  esac

  pane_meta=$(fm_send_meta_for_key_value "$STATE" herdr_pane_id "$raw" 2>/dev/null || true)
  if [ -n "$pane_meta" ]; then
    session=$(fm_meta_get "$pane_meta" herdr_session)
    hint="${session:-<herdr-session>}:$raw"
    id=$(fm_send_id_from_meta "$pane_meta")
    echo "error: target '$raw' matches herdr_pane_id in $pane_meta but is missing its herdr session prefix; expected <herdr-session>:<pane-id> such as '$hint' or use 'fm-$id' (tried meta=$STATE/$raw.meta; backend=herdr)" >&2
    return 1
  fi

  meta=$(fm_backend_meta_for_window "$raw" "$STATE" 2>/dev/null || true)
  if [ -n "$meta" ]; then
    target=$(fm_backend_target_of_meta "$meta")
    if [ -z "$target" ]; then
      echo "error: no backend target recorded in $meta (tried explicit target '$raw' via recorded window/terminal; backend=from-meta)" >&2
      return 1
    fi
    RESOLVED_TARGET=$target
    TARGET_BACKEND=$(fm_backend_of_meta "$meta")
    TARGET_META=$meta
    TARGET_HARNESS=$(fm_meta_get "$meta" harness)
    RESOLUTION_TRIED="explicit target '$raw' matched $meta; backend=$TARGET_BACKEND"
    return 0
  fi

  case "$raw" in
  *:*)
    colons=$(fm_send_count_colons "$raw")
    if [ "$colons" -ge 2 ]; then
      assumed=herdr
    else
      assumed=tmux
    fi
    if ! fm_backend_target_exists "$assumed" "$raw"; then
      echo "error: explicit target '$raw' is not a live $assumed endpoint (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed). Use fm-<id> for a recorded task/lane, or pass a target whose backend endpoint can be verified." >&2
      return 1
    fi
    RESOLVED_TARGET=$raw
    TARGET_BACKEND=$assumed
    RESOLUTION_TRIED="meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=$assumed; endpoint=verified"
    return 0
    ;;
  esac

  echo "error: target '$raw' is not resolvable (tried meta=$STATE/$raw.meta; metadata window/terminal lookup; backend=none). Use fm-$raw for a recorded task/lane, or pass a well-formed explicit backend target such as session:window." >&2
  return 1
}

RAW_TARGET=$1
fm_send_resolve_target "$RAW_TARGET" || exit 1
T=$RESOLVED_TARGET
shift

# Supervision lease guard: a steer is overlap territory between the two Pi
# supervision actors, so refuse while the OTHER actor holds this task's live
# lease. A home with no supervision branch has no lease files and passes
# untouched (contract: bin/fm-lease-lib.sh).
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
if [ -n "$TARGET_META" ]; then
  LEASE_GUARD_TASK=$(fm_send_id_from_meta "$TARGET_META")
  if [ -n "$LEASE_GUARD_TASK" ]; then
    fm_lease_guard "$LEASE_GUARD_TASK" "steer (fm-send)"
    trap 'fm_lease_guard_release' EXIT
  fi
fi

# Collect --resolve-key flags (answerer-closes; see the header contract). They
# must precede --key or the message text; everything after the last flag is the
# message exactly as before, so ordinary sends are byte-identical.
RESOLVE_KEYS=
FIRE_AND_FORGET_ID=
fm_send_add_resolve_key() { # <key>
  local k=$1
  case "$k" in
  '' | *[!A-Za-z0-9._-]*)
    echo "error: --resolve-key '$k' is not a valid decision key (allowed: A-Z a-z 0-9 . _ -)" >&2
    return 1
    ;;
  esac
  case " $RESOLVE_KEYS " in
  *" $k "*)
    echo "error: duplicate --resolve-key '$k'" >&2
    return 1
    ;;
  esac
  RESOLVE_KEYS="${RESOLVE_KEYS}${RESOLVE_KEYS:+ }$k"
}
while :; do
  case "${1:-}" in
  --resolve-key)
    [ $# -ge 2 ] || {
      echo "error: --resolve-key requires a key" >&2
      exit 1
    }
    fm_send_add_resolve_key "$2" || exit 1
    shift 2
    ;;
  --resolve-key=*)
    fm_send_add_resolve_key "${1#--resolve-key=}" || exit 1
    shift
    ;;
  --fire-and-forget)
    [ $# -ge 2 ] || {
      echo "error: --fire-and-forget requires a delivery id" >&2
      exit 1
    }
    [ -z "$FIRE_AND_FORGET_ID" ] || {
      echo "error: duplicate --fire-and-forget" >&2
      exit 1
    }
    FIRE_AND_FORGET_ID=$2
    shift 2
    ;;
  --fire-and-forget=*)
    [ -z "$FIRE_AND_FORGET_ID" ] || {
      echo "error: duplicate --fire-and-forget" >&2
      exit 1
    }
    FIRE_AND_FORGET_ID=${1#--fire-and-forget=}
    shift
    ;;
  *) break ;;
  esac
done


  fm_backend_validate "$TARGET_BACKEND" || exit 1


# Classify a from-firstmate -> secondmate request. Only a task selector resolved
# through this home's meta whose authoritative kind is secondmate is marked: the
# secondmate then routes its reply via the status path (see fm-marker-lib.sh).
# An explicit backend target (the escape hatch for endpoints outside this home)
# and any crewmate/scout target are left unmarked, and so is the --key path.
MARK_FROM_FIRSTMATE=0
TARGET_TASK_ID=
fm_send_known_undelivered_cleanup() { return 0; }


# Validate the answerer-closes request before any durable mutation or send: the
# target must have a task ledger in THIS home, the send must carry an answer
# message, and every named key must be open right now in that ledger per the
# ONE authoritative fold (status_open_decisions). Refusing here, before the
# send, is what keeps a mistyped key loud instead of delivering an answer that
# silently leaves its decision open.
RESOLVE_STATUS_FILE=
# Which ledger each answered key belongs to. A key still open in the status log
# is owned by the status log: fm-captain-hold's `complete` closes that live copy
# at the moment it transfers a decision to its durable captain-held task, so
# "still open in status" and "already held" are the two sides of one transfer,
# never both at once. Checking the backlog only for keys the status log no
# longer owns also keeps the common path free of any backlog read.
RESOLVE_STATUS_KEYS=
RESOLVE_HOLD_KEYS=
RESOLVE_CLOSE_MAX=$FM_LINE_CAP_DEFAULT

# Resolve a --resolve-key key that the status log no longer owns to the
# captain-held task that carries it: the key as a task id itself (the collapsed
# identity - a captain call IS a task held for the captain), then the legacy
# derived `<task>-decision-<key>` identity for pre-collapse rows. Answerable
# means not closed and still carrying the captain-hold annotations tasks-axi
# preserves even past a hold-until date.
fm_send_hold_resolved_id() { # <task-id> <decision-key>
  local show id state hold_kind
  # shellcheck source=bin/fm-tasks-axi-lib.sh
  . "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
  fm_tasks_axi_compatible || return 1
  for id in "$2" "$1-decision-$2"; do
    show=$(FM_HOME="$FM_HOME" FM_DATA_OVERRIDE='' "$SCRIPT_DIR/fm-tasks-axi.sh" show "$id" --full 2>/dev/null) || continue
    state=$(printf '%s\n' "$show" | sed -n 's/^  state: //p' | head -1)
    hold_kind=$(printf '%s\n' "$show" | sed -n 's/^  hold_kind: //p' | head -1)
    [ "$state" != "done" ] || continue
    [ "$hold_kind" = captain ] || continue
    printf '%s\n' "$id"
    return 0
  done
  return 1
}

# Close-note body for --resolve-key. Ordinary keys keep answered: <excerpt>.
# A pending-reply-* key uses the owning library's vocabulary so the reserved-key
# fold actually closes it (fm_pending_reply_close_note_for_key).
fm_send_resolve_close_note() { # <key> <excerpt>
  case "$1" in
    pending-reply-*)
      # Explicitly close a historical reserved key without reviving reply tracking.
      printf 'pending-reply-resolved: task=%s pending-reply-id=%s via=operator-resolve-key %s' "$RESOLVE_TASK_ID" "${1#pending-reply-}" "$2"
      ;;
    *) printf 'answered: %s' "$2" ;;
  esac
}

if [ -n "$FIRE_AND_FORGET_ID" ]; then
  printf '%s' "$FIRE_AND_FORGET_ID" | grep -Eq '^[a-f0-9]{16}$' ||
    {
      echo "error: --fire-and-forget delivery id must be 16 lowercase hex characters" >&2
      exit 1
    }
  [ "$MARK_FROM_FIRSTMATE" = 1 ] ||
    {
      echo "error: --fire-and-forget requires a recorded secondmate task selector" >&2
      exit 1
    }
  [ -z "$RESOLVE_KEYS" ] ||
    {
      echo "error: --fire-and-forget cannot accompany --resolve-key" >&2
      exit 1
    }
fi

if [ -n "$RESOLVE_KEYS" ]; then
  if [ -z "$TARGET_SELECTOR" ] || [ -z "$TARGET_META" ]; then
    echo "error: --resolve-key needs a task selector resolved through this home's metadata; an explicit backend target has no decision ledger here" >&2
    exit 1
  fi
  if [ "${1:-}" = "--key" ]; then
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 1
  fi
  if [ -z "$*" ]; then
    echo "error: --resolve-key requires a nonempty answer message" >&2
    exit 1
  fi
  RESOLVE_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
  RESOLVE_STATUS_FILE="$STATE/$RESOLVE_TASK_ID.status"
  resolve_open_set=$(status_open_decisions "$RESOLVE_STATUS_FILE")
  for k in $RESOLVE_KEYS; do
    case "$resolve_open_set" in
    "$k"$'\t'* | *$'\n'"$k"$'\t'*)
      RESOLVE_STATUS_KEYS="${RESOLVE_STATUS_KEYS}${RESOLVE_STATUS_KEYS:+ }$k"
      continue
      ;;
    esac
    # Not open in the status log. A decision already transferred to its durable
    # captain-held task is exactly this case, and it is answerable - just
    # through the other ledger - so check there before refusing.
    if resolved_hold_id=$(fm_send_hold_resolved_id "$RESOLVE_TASK_ID" "$k"); then
      RESOLVE_HOLD_KEYS="${RESOLVE_HOLD_KEYS}${RESOLVE_HOLD_KEYS:+ }$resolved_hold_id"
      continue
    fi
    echo "error: --resolve-key '$k': no open decision or blocker with that key in $RESOLVE_STATUS_FILE, and no captain-held task '$k' or '$RESOLVE_TASK_ID-decision-$k' still open (already closed or mistyped). Re-check the OPEN DECISIONS listing, then resend without that key or with the right one; nothing was sent." >&2
    exit 1
  done
  # The decision-answer partition (the header's "Answering a decision"
  # contract): a key that is an open needs-decision, or already a captain-held
  # task, is a decision, and answering one is main-owned while attended. A
  # blocked: key is ordinary steering and takes no partition guard. Under the
  # away-posture record the guard passes the branch instead (relocation:
  # bin/fm-lease-lib.sh); which findings firstmate may decide at all stays
  # ask-user-authority's judgment, for either actor.
  RESOLVE_IS_DECISION=0
  [ -z "$RESOLVE_HOLD_KEYS" ] || RESOLVE_IS_DECISION=1
  for k in $RESOLVE_STATUS_KEYS; do
    [ "$(_fm_open_set_verb "$resolve_open_set" "$k")" = needs-decision ] && RESOLVE_IS_DECISION=1
  done
  if [ "$RESOLVE_IS_DECISION" -eq 1 ]; then
    fm_lease_forbid_branch "decision answer (fm-send --resolve-key)" --away-relocated
  fi
  # Refuse before send when a named status-log key cannot actually close: a
  # reserved key with an answered: note is a silent no-op in the fold.
  # The cap bounds the line that is actually APPENDED, and the self-announced
  # append stamps each line with its emission time. Reserve that stamp's width
  # here so the probe below measures the same bytes the writer will produce and
  # the close record stays inside the cap this refusal cites.
  RESOLVE_CLOSE_MAX=$((FM_LINE_CAP_DEFAULT - $(status_stamp_width)))
  [ "$RESOLVE_CLOSE_MAX" -ge 0 ] || RESOLVE_CLOSE_MAX=0
  resolve_excerpt=$(printf '%s' "$*" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_STATUS_KEYS; do
    probe=$(fm_send_resolve_close_note "$k" "$resolve_excerpt")
    if ! _fm_decision_key_transition_allowed "$k" "$probe"; then
      echo "error: --resolve-key '$k' cannot take effect: this key is reserved for its owning library, and this send cannot produce a close note that library's fold will accept. Refusing rather than writing a silent no-op; nothing was sent." >&2
      exit 1
    fi
    probe_line="resolved [key=$k]: $probe"
    fm_cap_line_var "$probe_line" "$RESOLVE_CLOSE_MAX"
    probe_key=$(_fm_decision_key "$FM_LINE_CAP_LINE") || probe_key=
    if [ "$(status_line_verb "$FM_LINE_CAP_LINE")" != resolved ] || [ "$probe_key" != "$k" ]; then
      echo "error: --resolve-key cannot close a decision key of length ${#k}: its ${#probe_line}-character close record exceeds the $FM_LINE_CAP_DEFAULT-character status-line cap, and truncation would remove the structural key delimiter. Refusing rather than writing an ineffective close; nothing was sent." >&2
      exit 1
    fi
  done
fi

# Close each answered decision in this home's ledger, only after the answer is
# durably sent: enqueued on the inbox plane, submit-confirmed on the typed
# plane. An append failure exits nonzero with the manual close
# command; the decision then stays open and re-surfaces, never silently lost.
# All of one answer's closes are this home's own bookkeeping, written by the
# very turn that answered the decisions, so they go through ONE guarded
# self-announced append (bin/fm-wake-lib.sh). That records the appended byte
# range so separate --resolve-key answers do not each wake this same session,
# including when this home already folded those bytes through OPEN DECISIONS
# without a matching watcher seen marker; any concurrent foreign status bytes,
# or a worker line the fold read but never listed, leave the watcher's wake
# path untouched.
fm_send_close_resolved_keys() { # <answer-text>
  local note=$1 k close_note append_rc still manual_close_cmd close_lines=() i=0
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_STATUS_KEYS; do
    close_note=$(fm_send_resolve_close_note "$k" "$note")
    fm_cap_line_var "resolved [key=$k]: $close_note" "$RESOLVE_CLOSE_MAX"
    close_lines+=("$FM_LINE_CAP_LINE")
  done
  [ "${#close_lines[@]}" -gt 0 ] || return 0
  append_rc=0
  fm_wake_status_append_self_announced "$STATE" "$RESOLVE_STATUS_FILE" "${close_lines[@]}" || append_rc=$?
  if [ "$append_rc" -eq 2 ]; then
    printf -v manual_close_cmd ' %q' "${close_lines[@]}"
    printf -v manual_close_cmd "printf '%%s\\n'%s >> %q" "$manual_close_cmd" "$RESOLVE_STATUS_FILE"
    echo "error: the answer was delivered to $T, but the close for decision key(s) '$RESOLVE_STATUS_KEYS' could not be appended to $RESOLVE_STATUS_FILE. Close it manually with: $manual_close_cmd - do not resend the answer." >&2
    return 1
  fi
  still=$(status_open_decisions "$RESOLVE_STATUS_FILE")
  for k in $RESOLVE_STATUS_KEYS; do
    case "$still" in
    "$k"$'\t'* | *$'\n'"$k"$'\t'*)
      printf -v manual_close_cmd "printf '%%s\\n' %q >> %q" "${close_lines[$i]}" "$RESOLVE_STATUS_FILE"
      echo "error: the answer was delivered to $T, but decision key '$k' is still open in $RESOLVE_STATUS_FILE; it may have been reopened concurrently or the fold did not accept the close. Close it manually with: $manual_close_cmd - do not resend the answer." >&2
      return 1
      ;;
    esac
    i=$((i + 1))
  done
}

# Feed the answered captain-held tasks to the ONE keyed-answer intake, as keyed
# lines, exactly the way every other channel does. fm-send decides nothing here:
# it does not build a decision record or choose a close path; the keys were
# already resolved to task ids above, so the intake needs no legacy origin.
fm_send_feed_resolved_holds() { # <answer-text>
  local note=$1 k lines=''
  [ -n "$RESOLVE_HOLD_KEYS" ] || return 0
  note=$(printf '%s' "$note" | tr '\n\r\t' '   ' | LC_ALL=C tr -d '\000-\037\177')
  for k in $RESOLVE_HOLD_KEYS; do
    lines="${lines}${k}"$'\t'"${note}"$'\t'$'\n'
  done
  if ! printf '%s' "$lines" | "$SCRIPT_DIR/fm-captain-hold.sh" answers \
    --source "a firstmate answer sent to $RESOLVE_TASK_ID" >/dev/null 2>&1; then
    echo "error: the answer was delivered to $T, but this captain-held task could not be closed: ${RESOLVE_HOLD_KEYS}. Close it with fm-captain-hold.sh answer - do not resend the answer." >&2
    return 1
  fi
}

# Resolve the target's harness from its meta (recorded by fm-spawn), used only to
# scope the codex `$<skill>` popup-settle below. A task selector carries
# meta; an explicit backend-target escape hatch has none, so its harness is
# unknown and treated as non-codex (the safe default that keeps the fast path).
# The target's BACKEND comes from selector meta, from matching an explicit target
# back to recorded meta, or from strict explicit-target shape validation.
# Do not add a separate passive liveness preflight here. Active send paths own
# backend readiness: herdr, for example, must route through its session-aware
# target_ready path before sending, while zellij verifies pane labels in its
# send implementation. A failed backend send is still surfaced below as a hard
# error with the attempted resolution attached.

# Typed input can execute a shell command after an agent exits. Serialize it
# with lifecycle control, and require relaunch (which reacquires capacity) for
# a preserved stopped worker. Inbox enqueue itself cannot reactivate an agent.
SEND_CONTROL_LOCK=
fm_send_release_control() {
  [ -z "$SEND_CONTROL_LOCK" ] || fm_lock_release "$SEND_CONTROL_LOCK"
  fm_lease_guard_release
}
fm_send_require_active_worker() {
  local id
  [ -n "$TARGET_META" ] || return 0
  id=$(fm_send_id_from_meta "$TARGET_META")
  SEND_CONTROL_LOCK="$STATE/.control-$id.lock"
  fm_lock_try_acquire "$SEND_CONTROL_LOCK" || {
    echo "error: another lifecycle action is running for $id; nothing was typed" >&2
    return 1
  }
  trap fm_send_release_control EXIT
  if [ ! -f "$TARGET_META" ] ||
     [ "$(fm_backend_target_of_meta "$TARGET_META")" != "$T" ] ||
     [ "$(fm_backend_of_meta "$TARGET_META")" != "$TARGET_BACKEND" ]; then
    echo "error: task $id changed endpoint before typed delivery; nothing was typed" >&2
    return 1
  fi
  if [ -n "$(fm_meta_get "$TARGET_META" afk_worker_stopped)" ]; then
    echo "error: task $id has a confirmed-stop receipt; use fm-control relaunch to reacquire an AI worker slot before reactivation (ordinary inbox messages remain preserved)" >&2
    return 1
  fi
}

if [ "${1:-}" = "--key" ]; then
  [ -z "$FIRE_AND_FORGET_ID" ] ||
    {
      echo "error: --fire-and-forget cannot accompany --key" >&2
      exit 1
    }
  case "$*" in
  *--resolve-key*)
    echo "error: --resolve-key cannot accompany --key; answering a decision requires a text answer" >&2
    exit 1
    ;;
  esac
  key=$2
  semantic_key=$(fm_send_normalize_key "$key")
  fm_send_require_active_worker || exit 1
  if ! fm_backend_send_key "$TARGET_BACKEND" "$T" "$key" "$EXPECTED_LABEL"; then
    echo "error: key '$key' not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  fm_send_clear_after_interrupt "$semantic_key" || exit 1
  fm_send_record_interrupt "$semantic_key" || exit 1
else
  MESSAGE=$*
  if [ -z "${MESSAGE//[[:space:]]/}" ]; then
    echo "error: a text steer requires a nonempty message; nothing was sent (an empty marked request would deliver only marker and correlation bytes and leave the parent waiting on a reply to nothing)" >&2
    exit 1
  fi

  # The pre-marker answer text, kept for the closing resolved note so the
  # durable ledger records the plain answer without marker or corr bytes.
  RESOLVE_ANSWER_TEXT=$MESSAGE

  # Data-plane selection (see the header): text addressed to a task selector
  # resolved through this home's metadata rides the inbox plane, unless it is
  # a LOCAL harness-native invocation that must reach the harness's own parser
  # - a leading "/" (slash command), or a leading "$" to a codex target (skill
  # invocation). A remote secondmate selector always rides the inbox: its
  # requests are marked, and a marked request reaches the harness as
  # marker-prefixed chat rather than a parser command anyway, so no remote
  # text has a typed plane to lose. An explicit backend target stays typed
  # even when it happens to match local metadata: it names an endpoint, not a
  # task, the same boundary that keeps it unmarked and outside --resolve-key.
  # Classification reads the pre-marker text so a marked secondmate request
  # and a plain crewmate steer classify identically. It deliberately does NOT
  # promise that a marked parser-native secondmate request executes as a parser
  # command: the pre-existing marker-first wire bytes are retained in stage 1.
  INBOX_PLANE=0
  if [ -n "$TARGET_SELECTOR" ]; then
    if [ -n "$FIRE_AND_FORGET_ID" ] || [ "$TARGET_BACKEND" = remote ]; then
      INBOX_PLANE=1
    else
      case "$RESOLVE_ANSWER_TEXT" in
      /*) ;;
      \$*) [ "$TARGET_HARNESS" = codex ] || INBOX_PLANE=1 ;;
      *) INBOX_PLANE=1 ;;
      esac
    fi
  fi

  if [ "$INBOX_PLANE" = 1 ]; then
    INBOX_TASK_ID=$(fm_send_id_from_meta "$TARGET_META")
    INBOX_META_LOCK=$(fm_meta_lock_path "$TARGET_META") || exit 1
    if ! fm_task_inbox_lock_acquire "$INBOX_META_LOCK"; then

      echo "error: steer not sent to $INBOX_TASK_ID: its task metadata could not be locked for final delivery validation" >&2
      exit 1
    fi
    CURRENT_INBOX_TARGET=
    CURRENT_INBOX_BACKEND=
    CURRENT_INBOX_SPAWN_GEN=
    if [ -f "$TARGET_META" ]; then
      CURRENT_INBOX_TARGET=$(fm_backend_target_of_meta "$TARGET_META")
      CURRENT_INBOX_BACKEND=$(fm_backend_of_meta "$TARGET_META")
      CURRENT_INBOX_SPAWN_GEN=$(fm_meta_get "$TARGET_META" spawn_gen)
    fi
    if [ "$CURRENT_INBOX_TARGET" != "$T" ] ||
      [ "$CURRENT_INBOX_BACKEND" != "$TARGET_BACKEND" ] ||
      { [ -n "${FM_SEND_EXPECTED_SPAWN_GEN:-}" ] &&
        [ "$CURRENT_INBOX_SPAWN_GEN" != "$FM_SEND_EXPECTED_SPAWN_GEN" ]; } ||
      [ -n "$(fm_meta_get "$TARGET_META" remote_host)" ]; then
      fm_lock_release "$INBOX_META_LOCK"

      echo "error: steer not sent to $INBOX_TASK_ID: the task retired or changed endpoint during target resolution" >&2
      exit 1
    fi
    if [ "${FM_SEND_IDEMPOTENT:-0}" = 1 ]; then
      INBOX_RECORD=$(fm_task_inbox_write_idempotent "$STATE" "$INBOX_TASK_ID" "$MESSAGE" \
        "${FIRE_AND_FORGET_ID:+fire-and-forget}") || inbox_write_rc=$?
    else
      INBOX_RECORD=$(fm_task_inbox_write "$STATE" "$INBOX_TASK_ID" "$MESSAGE" \
        "${FIRE_AND_FORGET_ID:+fire-and-forget}") || inbox_write_rc=$?
    fi
    if [ "${inbox_write_rc:-0}" -ne 0 ]; then
      fm_lock_release "$INBOX_META_LOCK"

      echo "error: steer not sent to $INBOX_TASK_ID: its inbox record could not be written under $STATE/$INBOX_TASK_ID.inbox" >&2
      exit 1
    fi
    fm_lock_release "$INBOX_META_LOCK"
    # Enqueue IS durable delivery to the task's record: mark the pending
    # expectation delivered now, without resolving it - only a correlated
    # parent report acknowledges the request.

    # The answer is durably sent: close each answered decision at enqueue time
    # (answerer-closes; see the header contract).
    if [ -n "$RESOLVE_KEYS" ]; then
      fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
      fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
    fi
    # Ring the doorbell, best-effort: no ring outcome changes the exit status,
    # because the watcher owns loss detection from here, either through its
    # bounded re-ring ladder or direct unavailable-endpoint recovery.
    ring_rc=0
    fm_task_inbox_ring "$TARGET_BACKEND" "$T" "$INBOX_RECORD" "$EXPECTED_LABEL" || ring_rc=$?
    ring_retry="the watcher will re-ring"
    if [ -n "$FIRE_AND_FORGET_ID" ] \
      && [ -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/wait-no-turns" ]; then
      case "$ring_rc" in
      1|2)
        if fm_task_inbox_mark_retry "$STATE" "$INBOX_TASK_ID" "$INBOX_RECORD"; then
          ring_retry="the watcher will ring it once more"
        else
          ring_retry="its one retry ring could not be recorded, so nothing will ring it again"
        fi
        ;;
      esac
    fi
    case "$ring_rc" in
    1) echo "fm-send: doorbell skipped (composer visibly holds pending text); the steer is durably recorded at $INBOX_RECORD and $ring_retry" >&2 ;;
    2) echo "fm-send: doorbell did not reach $T; the steer is durably recorded at $INBOX_RECORD and $ring_retry" >&2 ;;
    3) echo "fm-send: doorbell not typed because the agent in $T has exited; the steer is durably recorded at $INBOX_RECORD for recovery (stuck-crewmate-recovery), and the watcher will not re-ring a dead pane" >&2 ;;
    esac
    exit 0
  fi
  # Slash commands open a completion popup in some TUIs (verified on codex);
  # submitting too fast selects nothing, so give the popup time to settle before
  # the (retried) Enter. Codex opens the same kind of popup for a `$<skill>`
  # invocation, so a `$...` message to a codex target gets the same settle. That
  # `$` case is scoped to codex on purpose: unlike `/`, a leading `$` commonly
  # starts ordinary text ("$5/month", "$HOME"), so a universal `$` rule would
  # needlessly slow plain text to claude/opencode/pi. The target backend's
  # verified submit retry still backs the settle up either way.
  case "$*" in
  /*) settle=1.2 ;;
  \$*)
    if [ "$TARGET_HARNESS" = codex ]; then settle=1.2; else settle=0.3; fi
    ;;
  *) settle=0.3 ;;
  esac
  # Per-harness submit-confirm budget. agy's bare `>` composer verdict is
  # `unknown`, so a landed submit is acknowledged only by the idle-to-busy
  # transition poll, and agy renders its verified busy footer well after the
  # shared budget expires: ~1.5s after Enter for a short steer, ~4-5s for a
  # realistic longer brief (live-measured, agy 1.2.1), against the shared
  # default's 3 x 0.4s. With the shared default a typed steer to an agy
  # endpoint was reported exit-1 non-delivery for a message that landed and
  # ran, inviting a duplicate resend. agy typed targets get a longer default
  # budget (~8s at the default cadence, twice the worst measured render); an
  # explicit FM_SEND_RETRIES still wins, and every other harness keeps the
  # shared 3-retry default untouched.
  case "$TARGET_HARNESS" in
    agy) retries=${FM_SEND_RETRIES:-20} ;;
    *) retries=${FM_SEND_RETRIES:-3} ;;
  esac
  sleep_s=${FM_SEND_SLEEP:-0.4}
  # Type once, submit, verify. Only exact empty confirms delivery; every other
  # verdict preserves the loud refusal boundary. Only LOCAL targets reach this
  # block: remote text rides the inbox leg above, and remote --key exits
  # earlier.
  send_rc=0
  fm_send_require_active_worker || exit 1
  if verdict=$(fm_backend_send_text_submit "$TARGET_BACKEND" "$T" "$MESSAGE" "$retries" "$sleep_s" "$settle" "$EXPECTED_LABEL"); then
    :
  else
    send_rc=$?
  fi
  if [ "$send_rc" -ne 0 ]; then
    fm_send_known_undelivered_cleanup ||
      echo "error: known-undelivered pending-reply state could not be reset for $TARGET_TASK_ID" >&2
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
  fi
  case "$verdict" in
  empty)
    ;;
  send-failed)
    fm_send_known_undelivered_cleanup ||
      echo "error: known-undelivered pending-reply state could not be reset for $TARGET_TASK_ID" >&2
    echo "error: text not sent to $T ($TARGET_BACKEND send failed; tried $RESOLUTION_TRIED)" >&2
    exit 1
    ;;
  pending)
    # The text was typed into the live target and Enter was sent; only the
    # submit read-back stayed unconfirmed (e.g. a busy harness queues the
    # steer and keeps rendering it). That is not a proven failure, so never
    # re-type the message: verify the pane instead. Exit 3 is the documented
    # delivered-unconfirmed status.
    # The pending-reply expectation is deliberately NOT discarded here:
    # dropping it would silently stop tracking a marked request that very
    # likely landed. It stays armed on its unconfirmed-delivery marker, so a
    # correlated report still resolves it and an unanswered one still
    echo "fm-send: text delivered to $T but submission is unconfirmed (verdict=pending; tried $RESOLUTION_TRIED); do not retype or blindly resend - verify with fm-peek.sh, then re-send '--key Enter' only if the composer still holds the text" >&2
    exit 3
    ;;
  *)

    echo "error: text not submitted to $T (delivery unconfirmed; verdict=${verdict:-unknown}; tried $RESOLUTION_TRIED)" >&2
    exit 1
    ;;
  esac
  # Delivery confirmed. Mark the pending expectation delivered without resolving
  # it: only a correlated parent report acknowledges the request.

  # Delivery is fully confirmed: close each answered decision in this home's
  # ledger (answerer-closes; see the header contract).
  if [ -n "$RESOLVE_KEYS" ]; then
    fm_send_close_resolved_keys "$RESOLVE_ANSWER_TEXT" || exit 1
    fm_send_feed_resolved_holds "$RESOLVE_ANSWER_TEXT" || exit 1
  fi
  # Submit landed with exact empty. Confirmation only proves the text was
  # accepted; the harness still needs a beat to spin up the
  # turn before its busy footer shows. Pause so an immediate peek catches the
  # crewmate actually working instead of the stale idle pane. FM_SEND_SETTLE=0
  # disables it. Scoped to this path only, never the shared submit core.
  [ "${FM_SEND_SETTLE:-1}" = 0 ] || sleep "${FM_SEND_SETTLE:-1}"
fi
