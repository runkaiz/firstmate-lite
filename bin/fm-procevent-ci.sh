#!/usr/bin/env bash
# Hand a no-mistakes CI-only wait to the existing process-event runner.
# Usage: fm-procevent-ci.sh arm <task-id>
#        fm-procevent-ci.sh poll <task-id> <worktree> <run-id> <branch> <pr-url>
#        fm-procevent-ci.sh classify|terminal <result-file>
#
# arm verifies the current branch's CI-only run, refuses a concurrent merge
# poll, and confirms a durable listener before the worker ends its turn.
# poll reattaches only that run, never starts a run or responds to a gate.
# Unchanged pending returns stay inside this shell, including across AXI hold
# expiry. The runner owns capture, wake delivery, single ownership and restart
# recovery. Every captured result ends this wait; no merge monitor is added.
# Readiness is only a no-mistakes drive outcome, checked against the current
# forge head. Missing required checks remain no-mistakes' responsibility.
# Results are evidence for the original worker to reattach, never authority to
# mark a run passed, merge, edit pipeline-owned code or answer an approval.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-$FM_ROOT}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-nm-run-lib.sh
. "$SCRIPT_DIR/fm-nm-run-lib.sh"
# shellcheck source=bin/fm-procevent-lib.sh
. "$SCRIPT_DIR/fm-procevent-lib.sh"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
field() { fm_nm_strip_quotes "$(fm_nm_field "$SNAPSHOT" "$1")"; }
snapshot() {
  SNAPSHOT=$(fm_nm_run_checked "$WT" 15 axi status) || return 1
  printf '%s\n' "$SNAPSHOT" | grep -q '^run:' || return 1
  [ "$(field id)" = "$RUN" ] && [ "$(field branch)" = "$BRANCH" ] \
    && [ "$(field pr)" = "$PR" ] || return 1
  [ "$(git -C "$WT" symbolic-ref --quiet --short HEAD)" = "$BRANCH" ] || return 1
  fm_pr_head_valid "$(field head_sha)"
}
ci_only() {
  fm_nm_run_is_executing "$SNAPSHOT" || return 1
  [ "$(field status)" != fixing ] || return 1
  # Read the declared table, not free text or a log's historical green marker.
  # Refuse missing/duplicate steps and any substantive step not completed.
  printf '%s\n' "$SNAPSHOT" | awk '
    /^[[:space:]]*steps\[[0-9]+\]\{step,status,findings,duration_ms\}:/ {
      table=1; next
    }
    table && /^[[:space:]]*[a-z-]+,/ {
      gsub(/^[[:space:]]+/, ""); split($0, row, ",")
      step=row[1]; state=row[2]; seen[step]++
      if (step == "ci") { if (state != "running") bad=1 }
      else if (state != "completed" && !(step == "rebase" && state == "skipped")) bad=1
      next
    }
    table { table=0 }
    END {
      n=split("intent rebase review test document lint push pr ci", required, " ")
      for (i=1; i<=n; i++) if (seen[required[i]] != 1) bad=1
      exit bad || !n
    }'
}
result() {
  printf 'ci_wait: %s\ntask: %s\nrun_id: %s\npr: %s\n' "$1" "$TASK" "$RUN" "$PR"
  printf 'evidence:\n%s\n' "${2:-$SNAPSHOT}"
}

case "${1:-}" in
  arm)
    [ "$#" -eq 2 ] || die 'usage: fm-procevent-ci.sh arm <task-id>'
    TASK=$2
    fm_pr_task_id_valid "$TASK" || die 'invalid task id'
    ARM_LOCK="$STATE/.ci-wait-$TASK.lock"
    fm_lock_acquire_wait "$ARM_LOCK" || die 'cannot lock CI handoff'
    trap 'fm_lock_release "$ARM_LOCK" || true' EXIT
    META="$STATE/$TASK.meta"
    [ -f "$META" ] && [ ! -L "$META" ] || die 'task metadata unavailable'
    [ "$(sed -n 's/^mode=//p' "$META" | tail -1)" = no-mistakes ] || die 'not a no-mistakes task'
    [ "$(sed -n 's/^kind=//p' "$META" | tail -1)" = ship ] || die 'not a ship task'
    WT=$(sed -n 's/^worktree=//p' "$META" | tail -1)
    [ -d "$WT" ] || die 'worktree unavailable'
    [ ! -e "$STATE/$TASK.check.sh" ] || die 'task already has a PR/custom monitor'
    if fm_procevent_ci_waiting "$STATE" "$TASK" "$FM_ROOT"; then die 'CI wait already registered'; fi
    BRANCH=$(git -C "$WT" symbolic-ref --quiet --short HEAD) || die 'branch unavailable'
    SNAPSHOT=$(fm_nm_run_checked "$WT" 15 axi status) || die 'cannot read no-mistakes run'
    RUN=$(field id); PR=$(field pr)
    if [ -z "$RUN" ] || ! fm_pr_url_parse "$PR"; then die 'no current run with a canonical PR'; fi
    if ! snapshot || ! ci_only; then die 'current run is not CI-only; keep driving its next gate/outcome'; fi
    # A run is the canonical source across homes. Equal task display names
    # in independent homes must not contend for an unrelated run's listener.
    case "$RUN" in ''|*[!A-Za-z0-9]*) die 'unsupported run identity' ;; esac
    SOURCE_ID=$(printf 'ci-%s' "$RUN" | tr '[:upper:]' '[:lower:]')
    fm_procevent_source_id_valid "$SOURCE_ID" || die 'unsupported run identity'
    [ ! -e "$STATE/procevent/$SOURCE_ID.source" ] || die 'CI run already registered'
    if fm_procevent_pending "$STATE" | grep -F "/$SOURCE_ID." >/dev/null; then
      die 'prior CI result still awaits firstmate acknowledgement'
    fi
    "$SCRIPT_DIR/fm-procevent.sh" register ci "$SOURCE_ID" -- \
      "$SCRIPT_DIR/fm-procevent-ci.sh" poll "$TASK" "$WT" "$RUN" "$BRANCH" "$PR"
    if ! "$SCRIPT_DIR/fm-procevent.sh" ensure-listening "$SOURCE_ID"; then
      # A failed confirmation must not leave a registration that later starts
      # a second drive behind a worker that retained ownership.
      if "$SCRIPT_DIR/fm-procevent.sh" retire "$SOURCE_ID"; then
        die 'CI listener not confirmed; registration retired, retain drive ownership'
      fi
      die 'CI handoff ownership uncertain; stop driving and ask firstmate to reconcile'
    fi
    printf 'CI wait delegated: %s run=%s; end this turn and wait for firstmate\n' "$SOURCE_ID" "$RUN"
    ;;
  poll)
    [ "$#" -eq 6 ] || die 'invalid CI poll arguments'
    TASK=$2 WT=$3 RUN=$4 BRANCH=$5 PR=$6
    if ! fm_pr_task_id_valid "$TASK" || ! fm_pr_url_parse "$PR"; then die 'invalid CI identity'; fi
    SNAPSHOT=
    while :; do
      if ! snapshot; then result monitor-error 'bound run/branch/PR unavailable or changed'; break; fi
      if ! fm_nm_run_is_executing "$SNAPSHOT"; then result action; break; fi
      rc=0
      DRIVE=$(fm_nm_run_bounded "$WT" 20 axi run --wait 1s 2>&1) || rc=$?
      # A gate, failure, revalidation, or unreadable daemon must reach the
      # original driver. Never respond, restart, or turn a CLI error into green.
      if ! snapshot; then result monitor-error "$DRIVE"; break; fi
      # v1.84.0 (4822244), emitAxiWaitElapsed/emitError: an elapsed
      # supported hold is error:<message>, exit 1, not a run-shaped success.
      # Match only our exact requested bound; all other errors stay visible.
      if [ "$rc" -eq 1 ] \
        && [ "$(fm_nm_strip_quotes "$(fm_nm_field "$DRIVE" error)")" = 'wait of 1s elapsed while driving the run' ] \
        && ! printf '%s\n' "$DRIVE" | grep -Eq '^[[:space:]]*(gate|outcome):'; then
        if ! fm_nm_run_is_executing "$SNAPSHOT"; then result action "$SNAPSHOT"; break; fi
        sleep 30
        continue
      fi
      if printf '%s\n' "$DRIVE" | grep -Eq '^[[:space:]]*(gate|outcome|error):'; then
        OUTCOME=$(fm_nm_strip_quotes "$(fm_nm_field "$DRIVE" outcome)")
        case "$OUTCOME" in
          checks-passed|passed|passed-with-override)
            DRIVE_HEAD=$(fm_nm_strip_quotes "$(fm_nm_field "$DRIVE" head_sha)")
            if ! fm_pr_head_valid "$DRIVE_HEAD" \
              || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$DRIVE" id)")" != "$RUN" ] \
              || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$DRIVE" branch)")" != "$BRANCH" ] \
              || [ "$(fm_nm_strip_quotes "$(fm_nm_field "$DRIVE" pr)")" != "$PR" ]; then
              result monitor-error 'green drive return lacks bound run/head/PR evidence'; break
            fi
            if [ "$DRIVE_HEAD" != "$(field head_sha)" ]; then
              result head-changed "$DRIVE"; break
            fi
            CORE=$(fm_nm_bounded "$WT" 15 gh pr view "$PR" --json url,headRefOid --jq '[.url,.headRefOid] | @tsv') \
              || { result monitor-error 'cannot verify current forge head'; break; }
            if [ "$CORE" != "$(printf '%s\t%s' "$PR" "$DRIVE_HEAD")" ]; then
              # A new forge head cannot inherit an old run's green return.
              result head-changed "$DRIVE"; break
            fi
            ;;
        esac
        if [ -z "$OUTCOME" ] && ! printf '%s\n' "$DRIVE" | grep -Eq '^[[:space:]]*gate:'; then
          result monitor-error "$DRIVE"; break
        fi
        result action "$DRIVE"; break
      fi
      if [ "$rc" -ne 0 ] || [ -z "$DRIVE" ]; then result monitor-error "$DRIVE"; break; fi
      # A pipeline-owned rebase or repair may return to Review. Keep holding
      # its same run without waking a worker merely to observe active work.
      if ! fm_nm_run_is_executing "$SNAPSHOT"; then result action "$SNAPSHOT"; break; fi
      # No model, status event, or wake is emitted for an elapsed pending hold.
      sleep 30
    done
    ;;
  classify)
    [ "$#" -eq 2 ] && [ -f "$2" ] || die 'result unavailable'
    sed -n 's/^ci_wait: //p' "$2" | head -1
    ;;
  terminal)
    [ "$#" -eq 2 ] && [ -f "$2" ] || die 'result unavailable'
    exit 0
    ;;
  *) die 'usage: fm-procevent-ci.sh arm|poll|classify|terminal' ;;
esac
