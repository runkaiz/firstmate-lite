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

wait_path() {
  local n=0
  until test -e "$1"; do
    n=$((n+1)); test "$n" -lt 100
    sleep .05
  done
}
bounded() { timeout 15 "$@"; }
for mode in main branch branch-outcome; do
  new_home "locking-$mode"; seed
  export FM_SUPERVISION_ACTOR=main
  if test "$mode" = branch-outcome; then
    branchseq=$(bash bin/fm-branch-outcome.sh append --task child --verdict captain --summary 'Ready outcome')
    bash bin/fm-branch-outcome.sh mark-read --through "$branchseq"
  fi
  queue child.status
  if test "$mode" = branch; then
    export FM_SUPERVISION_ACTOR=branch
    bash bin/fm-wake-grant.sh activate "$$" live-locks
    bash bin/fm-wake-grant.sh publish live-locks 1
  fi
  echo "SCENARIO metadata/presentation interleaving $mode"
  present
  bounded bash -c '
    . "$1/bin/fm-wake-lib.sh"
    . "$1/bin/fm-classify-lib.sh"
    lock=$(fm_meta_lock_path "$FM_HOME/state/child.meta")
    fm_lock_acquire_wait "$lock"
    touch "$FM_HOME/held"
    until test -e "$FM_HOME/release"; do sleep .05; done
    status_retire_presentation_task "$FM_HOME/state" child
    fm_lock_release "$lock"
    echo "OBSERVED: cleanup retired the status under the held metadata lock"
  ' _ "$ROOT" &
  holder=$!
  wait_path "$FM_HOME/held"
  if test "$mode" = branch-outcome; then
    bounded bash bin/fm-branch-outcome.sh mark-processed --through "$branchseq" &
  else
    bounded bash bin/fm-wake-drain.sh --ack-through "$SEQ" --recovery-generation "$GEN" &
  fi
  acker=$!
  wait_path "$FM_HOME/state/.inactive-outcome-reconcile.lock/pid"
  test ! -e "$FM_HOME/state/.status-presentation-lock"
  echo 'OBSERVED: receipt writer waits on metadata without retaining the presentation lock'
  touch "$FM_HOME/release"
  wait "$holder"
  wait "$acker"
  test ! -e "$FM_HOME/state/child.status"
  echo 'OBSERVED: cleanup and acknowledgement both finished within 15 seconds'
done
export FM_SUPERVISION_ACTOR=main
new_home replacement-snapshot; seed; queue child.status; present
bounded bash -c '
  . "$1/bin/fm-wake-lib.sh"
  . "$1/bin/fm-classify-lib.sh"
  lock=$(fm_meta_lock_path "$FM_HOME/state/child.meta")
  fm_lock_acquire_wait "$lock"
  touch "$FM_HOME/held"
  until test -e "$FM_HOME/release"; do sleep .05; done
  fm_lock_release "$lock"
' _ "$ROOT" &
holder=$!
wait_path "$FM_HOME/held"
bounded bash bin/fm-wake-drain.sh --ack-through "$SEQ" --recovery-generation "$GEN" &
acker=$!
wait_path "$FM_HOME/state/.inactive-outcome-reconcile.lock/pid"
printf 'failed: newer failure during acknowledgement\n' >> "$FM_HOME/state/child.status"
present
touch "$FM_HOME/release"
wait "$holder"
wait "$acker"
test "$(receipts)" = 0
cat "$FM_HOME/state/.main.status-wake-presented"
endpoint=$(wc -c < "$FM_HOME/state/child.status" | tr -d ' ')
awk -F '\t' -v endpoint="$endpoint" '$1==1 && $2=="child" && $3==endpoint {valid=1} END {exit !(valid && NR==1)}' "$FM_HOME/state/.main.status-wake-presented"
echo 'OBSERVED: old acknowledgement preserved the newer concurrently presented failure snapshot'
echo 'LIVE LOCK CHECKS COMPLETE'
