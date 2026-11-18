#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
EVIDENCE=/home/runkai/.no-mistakes/evidence/01M7R92E9KRV04638V2J0N9BQ0
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_CONFIG_OVERRIDE FM_DATA_OVERRIDE FM_PROJECTS_OVERRIDE FM_BACKEND FM_GATE_REFUSE_BYPASS FM_TEST_SEAM FM_INACTIVE_CREW_STATE_BIN FM_TASK_ID
export FM_SUPERVISION_ACTOR=main
LAB=$(mktemp -d "$ROOT/.fm-live.XXXXXX")
trap 'rm -rf "$LAB"' EXIT
export GIT_CONFIG_GLOBAL=/dev/null GIT_CONFIG_NOSYSTEM=1 GIT_AUTHOR_NAME=Validation GIT_AUTHOR_EMAIL=validation@example.invalid GIT_COMMITTER_NAME=Validation GIT_COMMITTER_EMAIL=validation@example.invalid
new_home() {
  export FM_HOME="$LAB/$1"
  bash bin/fm-lab-home.sh create "$FM_HOME" >/dev/null
  touch "$FM_HOME/config/supervision-host-off"
}
seed() {
  local id=${1:-child}
  mkdir -p "$FM_HOME/projects/$id"
  printf 'kind=ship\nmode=local-only\nharness=claude\nspawn_gen=live-%s\nworktree=%s/projects/%s\nproject=%s/projects/%s\nyolo=off\n' "$id" "$FM_HOME" "$id" "$FM_HOME" "$id" > "$FM_HOME/state/$id.meta"
  printf 'done: ready awaiting merge approval\n' > "$FM_HOME/state/$id.status"
}
queue() {
  FM_LIVE_KIND=${2:-signal} FM_LIVE_KEY=$1 bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_append "$FM_LIVE_KIND" "$FM_LIVE_KEY" "validation event"' _ "$ROOT"
}
present() {
  bash bin/fm-wake-drain.sh > "$FM_HOME/drain.out" 2> "$FM_HOME/drain.err"
  cat "$FM_HOME/drain.out" "$FM_HOME/drain.err"
  SEQ=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--ack-through \([0-9]*\) --recovery-generation .*/\1/p' "$FM_HOME/drain.err")
  GEN=$(sed -n 's/^WAKE_ACK_REQUIRED:.*--recovery-generation \([^ ]*\)$/\1/p' "$FM_HOME/drain.err")
  test -n "$SEQ" && test -n "$GEN"
}
ack() { bash bin/fm-wake-drain.sh --ack-through "$SEQ" --recovery-generation "$GEN"; }
receipts() {
  local files=("$FM_HOME/state/terminal-outcomes/"*.presented)
  if test -f "${files[0]}"; then printf '%s\n' "${files[@]}" | wc -l; else echo 0; fi
}
show_receipts() {
  local file
  for file in "$FM_HOME/state/terminal-outcomes/"*.presented; do test ! -f "$file" || cat "$file"; done
}
recovery() {
  : > "$FM_HOME/state/.wake-queue"
  bash -c '. "$1/bin/fm-wake-lib.sh"; fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" handling' _ "$ROOT"
}
for actor in main branch; do
  export FM_SUPERVISION_ACTOR=$actor
  for key in child.status child.turn-ended; do
    new_home "ordinary-$actor-$key"; seed
    queue "$key"
    if test "$actor" = branch; then
      bash bin/fm-wake-grant.sh activate "$$" live-grant
      bash bin/fm-wake-grant.sh publish live-grant 1
    fi
    echo "SCENARIO ordinary $actor $key"
    present
    test "$(receipts)" = 0
    ack
    test "$(receipts)" = 1
    test -f "$FM_HOME/state/child.meta"
    show_receipts
    echo 'OBSERVED: handled receipt recorded; awaiting-approval task retained'
  done
done
export FM_SUPERVISION_ACTOR=main
for path in ordinary recovery; do
  for mutation in append replace sibling unseen wrong-generation; do
    new_home "$path-$mutation"; seed
    if test "$path" = ordinary; then queue child.status; else recovery; fi
    echo "SCENARIO preserve $path $mutation"
    if test "$mutation" != unseen; then present; else SEQ=1; GEN=never-presented; fi
    case "$mutation" in
      append) printf 'failed: new validation failure\n' >> "$FM_HOME/state/child.status" ;;
      replace) mv "$FM_HOME/state/child.status" "$FM_HOME/old.status"; printf 'done: ready awaiting merge approval\n' > "$FM_HOME/state/child.status" ;;
      sibling) seed other ;;
      wrong-generation) if test "$path" = recovery; then recovery; else GEN=wrong-generation; fi ;;
    esac
    if test "$mutation" = unseen && test "$path" = recovery; then SEQ=0; GEN=$(sed 's/.*://' "$FM_HOME/state/.watcher-down"); fi
    ack
    if test "$mutation" = sibling; then test "$(receipts)" = 1; test ! -f "$FM_HOME/state/other.seen"; else
      # A normal nonzero queue acknowledgement remains sequence-bound even if its recovery generation is stale.
      if test "$path-$mutation" != ordinary-wrong-generation; then test "$(receipts)" = 0; fi
    fi
    echo "OBSERVED: receipts=$(receipts) after $mutation; status=$(tail -1 "$FM_HOME/state/child.status")"
  done
done
for terminal in done failed; do
  new_home "recovery-$terminal"; seed
  printf '%s: waiting for approval\n' "$terminal" > "$FM_HOME/state/child.status"
  recovery
  echo "SCENARIO empty recovery $terminal"
  present
  test "$SEQ" = 0
  bash bin/fm-wake-drain.sh --ack-through 0 --recovery-generation incorrect
  test "$(receipts)" = 0
  ack
  test "$(receipts)" = 1
  show_receipts
  echo 'OBSERVED: only the presented recovery generation recorded a terminal receipt'
done
new_home branch-outcome; seed
seq=$(bash bin/fm-branch-outcome.sh append --task child --verdict captain --summary 'Ready awaiting approval')
bash bin/fm-branch-outcome.sh mark-read --through "$seq"
test "$(receipts)" = 0
bash bin/fm-branch-outcome.sh mark-processed --through "$seq"
test "$(receipts)" = 1
show_receipts
echo 'OBSERVED: reading alone did not record a terminal receipt; processing did'
new_home merge-publication
export FM_LIVE_URL=https://github.com/validation/disposable/pull/17
bash -c '
  . "$1/bin/fm-merge-outcome-lib.sh"
  fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" child "$FM_LIVE_URL" self attended
  test ! -s "$FM_HOME/state/.wake-queue"
  fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" child "$FM_LIVE_URL" poll attended
  test "$FM_MERGE_OUTCOME_ALREADY_RECORDED" = true
  test ! -s "$FM_HOME/state/.wake-queue"
  cat "$FM_HOME/state/child.pr-poll-merge-notified"
  echo "OBSERVED: synchronous publication followed by poll emits no duplicate wake"
  fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" external "$FM_LIVE_URL" poll external
  fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" external "$FM_LIVE_URL" poll external
  test "$(wc -l < "$FM_HOME/state/.wake-queue")" = 1
  cat "$FM_HOME/state/.wake-queue"
  echo "OBSERVED: an external poll outcome emits exactly one durable merge wake"
  fm_merge_outcome_report "$FM_HOME" "$FM_HOME/state" child "https://github.com/validation/disposable/pull/18" poll external
  test "$(wc -l < "$FM_HOME/state/.wake-queue")" = 2
  echo "OBSERVED: a different PR remains eligible for a wake"
' _ "$ROOT"
new_home cleanup-queue
queue 'merged-child-https://github.com/validation/disposable/pull/17' check
queue 'merged-child-other-https://github.com/validation/disposable/pull/17' check
FM_LIVE_STATE="$FM_HOME/state" bash -c '
  . "$1/bin/fm-wake-lib.sh"
  fm_wake_append check inactive-outcome:old "inactive terminal outcome awaiting captain presentation: child=child state=done"
  fm_wake_append check inactive-outcome:sibling "inactive terminal outcome awaiting captain presentation: child=child-other state=done"
  fm_wake_append signal child.status "old event"
  fm_wake_queue_prune_task "$FM_LIVE_STATE" child
' _ "$ROOT"
cat "$FM_HOME/state/.wake-queue"
test "$(wc -l < "$FM_HOME/state/.wake-queue")" = 2
! grep -q 'child=child state\|merged-child-https\|child.status' "$FM_HOME/state/.wake-queue"
echo 'OBSERVED: cleanup pruned the retired task outcomes and preserved the similarly named sibling'
new_home local-landing
project="$FM_HOME/projects/demo"
mkdir -p "$project"
git -C "$project" init -qb main
git -C "$project" commit -q --allow-empty -m base
git -C "$project" switch -qc fm/child
printf 'landed product content\n' > "$project/result.txt"
git -C "$project" add result.txt
git -C "$project" commit -qm deliver
ship=$(git -C "$project" rev-parse HEAD)
git -C "$project" switch -q main
printf 'kind=ship\nmode=local-only\nharness=claude\nspawn_gen=live-landing\nproject=%s\nworktree=%s\nbranch=fm/child\nyolo=off\n' "$project" "$project" > "$FM_HOME/state/child.meta"
printf 'done: ready for local landing\n' > "$FM_HOME/state/child.status"
bash bin/fm-merge-local.sh child
test "$(git -C "$project" rev-parse main)" = "$ship"
test "$(receipts)" = 1
cat "$project/result.txt"
show_receipts
echo 'OBSERVED: real local fast-forward landed content and recorded the presentation receipt'
echo 'LIVE CLI CHECKS COMPLETE'
