#!/usr/bin/env bash
# Perform the approved local merge for a local-only ship task: fast-forward the
# project's default branch to the crewmate's immutable ship branch recorded in
# state/<task-id>.meta ("fm/<id>" for records created before that field existed).
#
# This is firstmate's merge gate-action (the captain's merge authority applied
# locally instead of via a GitHub PR). It is the one sanctioned exception to hard
# rule #1 "never run state-changing git in projects/", and it is narrow: it only
# runs for mode=local-only tasks, only after the captain approves (or yolo=on
# auto-approves), and only as a clean fast-forward - it refuses a diverged branch
# and tells you to have the crewmate rebase. See AGENTS.md prime directives,
# project management, and task lifecycle.
# The task's existing per-task control lock serializes the captain-hold check
# through that fast-forward. A still-held or unreadable row refuses before the
# merge, so a captain approval must be recorded as an `answer --release` before
# this entrypoint is invoked. The lock ends when the fast-forward returns;
# docs/captain-hold-lifecycle.md owns the accepted merge-to-cleanup residual.
# While away, only an existing yolo=on task with a reconciled done declaration,
# a clean worker copy at the exact ship head, and no captain hold may land.
# The supervisor still verifies the task's validation evidence and scope, as
# attended: a done declaration is not a machine attestation of passing tests.
# The away record lock spans the final authority read and synchronous merge.
# Usage: fm-merge-local.sh <task-id>
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
if [ "$#" -ne 1 ] || ! fm_pr_task_id_valid "$1"; then
  echo "error: invalid local merge request" >&2
  exit 2
fi
ID=$1
fm_backlog_directory_present "$STATE" "state directory" || {
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
}
META="$STATE/$ID.meta"

# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
"$FM_ROOT/bin/fm-guard.sh" || true
# Role partition: landing local-only work is MAIN-owned; the Pi supervision
# branch reports readiness while attended (contract: bin/fm-lease-lib.sh;
# no-op in homes without a branch actor). Away relocation reaches the narrow
# standing-authority and ready-head gate below. This precedes reading the
# task record, because the wrong
# actor is refused for its role whatever it says.
# shellcheck source=bin/fm-lease-lib.sh
. "$SCRIPT_DIR/fm-lease-lib.sh"
fm_lease_forbid_branch "local-only landing (fm-merge-local)" --away-relocated
# shellcheck source=bin/fm-afk-contract.sh
. "$SCRIPT_DIR/fm-afk-contract.sh"

[ -f "$META" ] || { echo "error: no meta for task $ID at $META" >&2; exit 1; }
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: local merge refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
MERGE_EXPECTED_SPAWN_GEN=$FM_BACKLOG_META_SPAWN_GEN

MERGE_CONTROL_LOCK=
merge_control_cleanup() {
  fm_afk_contract_lock_release || true
  [ -z "$MERGE_CONTROL_LOCK" ] || fm_lock_release "$MERGE_CONTROL_LOCK" || true
}
trap merge_control_cleanup EXIT
MERGE_CONTROL_LOCK="$STATE/.control-$ID.lock"
fm_lock_acquire_wait "$MERGE_CONTROL_LOCK"
if ! fm_backlog_meta_spawn_gen_optional "$META" "$STATE"; then
  echo "error: task $ID changed while waiting to merge; refusing: $FM_BACKLOG_TRANSITION_ERROR" >&2
  exit 1
fi
if [ "$FM_BACKLOG_META_SPAWN_GEN" != "$MERGE_EXPECTED_SPAWN_GEN" ]; then
  echo "error: task $ID changed incarnation while waiting to merge; refusing" >&2
  exit 1
fi

PROJ=$(grep '^project=' "$META" | cut -d= -f2-)
MODE=$(grep '^mode=' "$META" | cut -d= -f2- || true)
[ "$MODE" = local-only ] || { echo "error: task $ID is mode=$MODE, not local-only; merge PR tasks with bin/fm-pr-merge.sh <id> <PR url> after approval" >&2; exit 1; }

default_branch() {
  local ref branch
  ref=$(git -C "$PROJ" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null || true)
  if [ -n "$ref" ]; then
    echo "${ref#origin/}"
    return 0
  fi
  for branch in main master; do
    if git -C "$PROJ" show-ref --verify --quiet "refs/heads/$branch"; then
      echo "$branch"
      return 0
    fi
  done
  return 1
}

BRANCH=$(grep '^branch=' "$META" | cut -d= -f2- || true)
[ -n "$BRANCH" ] || BRANCH="fm/$ID"
if ! git check-ref-format --branch "$BRANCH" >/dev/null 2>&1; then
  echo "error: task $ID has an invalid recorded ship branch '$BRANCH'" >&2
  exit 1
fi
git -C "$PROJ" rev-parse --verify --quiet "refs/heads/$BRANCH" >/dev/null || { echo "error: branch $BRANCH does not exist in $PROJ" >&2; exit 1; }

DEFAULT=$(default_branch) || { echo "error: cannot determine default branch for $PROJ; expected origin/HEAD, main, or master" >&2; exit 1; }

# The project's main checkout must be on its default branch and clean, so the
# fast-forward lands predictably (firstmate never writes here otherwise).
cur=$(git -C "$PROJ" symbolic-ref --short HEAD 2>/dev/null || echo "")
[ "$cur" = "$DEFAULT" ] || { echo "error: $PROJ is on '$cur', expected default branch '$DEFAULT'; cannot merge safely" >&2; exit 1; }
if [ -n "$(git -C "$PROJ" status --porcelain 2>/dev/null | head -1)" ]; then
  echo "error: $PROJ has a dirty working tree; refusing to merge into it" >&2
  exit 1
fi

# Clean fast-forward only: DEFAULT must be an ancestor of BRANCH.
if ! git -C "$PROJ" merge-base --is-ancestor "$DEFAULT" "$BRANCH"; then
  echo "REFUSED: $BRANCH is not a fast-forward of $DEFAULT (it has diverged)." >&2
  echo "Have the crewmate rebase $BRANCH onto $DEFAULT, then retry." >&2
  exit 1
fi

before=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
MERGE_HEAD=$(git -C "$PROJ" rev-parse --verify "refs/heads/$BRANCH")
fm_afk_contract_lock_hold "$STATE" || {
  echo "error: local merge refused: away-posture record could not be locked" >&2
  exit 1
}
if fm_afk_contract_present "$STATE"; then
  FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" "$SCRIPT_DIR/fm-afk-contract.sh" validate >/dev/null || {
    echo "error: local merge refused: unreadable away-posture record" >&2
    exit 1
  }
fi
# Archive/refresh may have occurred since the early actor check.
fm_lease_forbid_branch "local-only landing (fm-merge-local)" --away-relocated
if fm_afk_contract_away_present "$STATE"; then
  [ "$(awk '/^yolo=/{n++; value=substr($0,6)} END{if(n==1) print value}' "$META")" = on ] || {
    echo "error: local merge while away requires existing task yolo=on authority" >&2
    exit 1
  }
  READY_LINE=$(status_current_line "$STATE/$ID.status" ship)
  [ "$(status_line_verb "$READY_LINE")" = 'done' ] || {
    echo "error: local merge while away requires a reconciled done declaration; validation failures and decision waits must be resolved" >&2
    exit 1
  }
  WORKTREE=$(awk '/^worktree=/{n++; value=substr($0,10)} END{if(n==1) print value}' "$META")
  SHIP_HEAD=$MERGE_HEAD
  WORKER_HEAD=$(git -C "$WORKTREE" rev-parse --verify HEAD 2>/dev/null || true)
  [ "$WORKER_HEAD" = "$SHIP_HEAD" ] && [ -z "$(git -C "$WORKTREE" status --porcelain 2>/dev/null)" ] || {
    echo "error: local merge while away requires a clean worker copy at the exact ship head" >&2
    exit 1
  }
fi
hold_status=0
FM_HOME="$FM_HOME" FM_STATE_OVERRIDE="$STATE" \
  "$SCRIPT_DIR/fm-captain-hold.sh" open "$ID" --distinguish-absent || hold_status=$?
case "$hold_status" in
  0)
    echo "error: task $ID is still held for the captain; release it before merging" >&2
    exit 1
    ;;
  1|3) ;;
  *)
    echo "error: could not determine whether task $ID is still held for the captain; refusing to merge" >&2
    exit 1
    ;;
esac
merge_status=0
git -C "$PROJ" merge --ff-only "$MERGE_HEAD" >/dev/null || merge_status=$?
fm_afk_contract_lock_release || true
fm_lock_release "$MERGE_CONTROL_LOCK" || true
MERGE_CONTROL_LOCK=
[ "$merge_status" -eq 0 ] || exit "$merge_status"
after=$(git -C "$PROJ" rev-parse --short "$DEFAULT")
# Opt-in fleet activity ledger (docs/fleet-ledger.md); off costs one file test.
[ ! -e "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}/fleet-ledger" ] || FM_HOME=$FM_HOME FM_STATE_OVERRIDE=$STATE "$SCRIPT_DIR/fm-fleet-ledger.sh" merged "$ID" local || true
echo "merged $BRANCH into local $DEFAULT ($before -> $after) in $PROJ"
