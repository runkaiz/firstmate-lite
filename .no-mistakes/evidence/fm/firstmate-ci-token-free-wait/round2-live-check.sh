#!/usr/bin/env bash
set -euo pipefail
ROOT=$PWD
LAB=$(mktemp -d "$ROOT/.test-ci-phase-tmp/fm-lab.XXXXXX")
unset FM_ROOT_OVERRIDE FM_STATE_OVERRIDE FM_DATA_OVERRIDE FM_CONFIG_OVERRIDE FM_PROJECTS_OVERRIDE
export FM_HOME="$LAB" FM_PROCEVENT_CLAIM_ROOT="$LAB/claims" NM_HOME="$LAB/nm"
export XDG_CONFIG_HOME="$LAB/xdg-config" XDG_STATE_HOME="$LAB/xdg-state" XDG_CACHE_HOME="$LAB/xdg-cache"
export TMPDIR="$LAB/tmp"
cleanup() {
  "$ROOT/bin/fm-procevent.sh" retire ci-livecheck >/dev/null 2>&1 || true
  rm -rf "$LAB"
}
trap cleanup EXIT
bin/fm-lab-home.sh create "$LAB"
mkdir -p "$LAB/tmp" "$LAB/wt" "$LAB/nm"
chmod 700 "$LAB/state"
ADAPTER="$ROOT/bin/fm-procevent-ci.sh"
RUNNER="$ROOT/bin/fm-procevent.sh"
PR=https://github.com/example/repo/pull/1
refuse() {
  local expected=$1
  shift
  local output rc=0
  output=$("$@" 2>&1) || rc=$?
  printf '%s\nexit=%s\n' "$output" "$rc"
  [ "$rc" -ne 0 ] && [[ "$output" == *"$expected"* ]]
}
printf '\nGenerated worker contract, default configuration:\n'
bin/fm-brief.sh task example --mode no-mistakes
sed -n '/^When only CI remains running/p' "$LAB/data/task/brief.md"
test -s "$LAB/data/task/brief.md"
printf '\nGenerated worker contract, wait-no-turns enabled:\n'
touch "$LAB/config/wait-no-turns"
bin/fm-brief.sh other example --mode no-mistakes
sed -n '/^When only CI remains running/p' "$LAB/data/other/brief.md"
printf '\nRefuse invalid task and unsupported mode:\n'
refuse 'invalid task id' "$ADAPTER" arm ../invalid
printf 'kind=ship\nmode=direct-PR\nworktree=%s\n' "$LAB/wt" > "$LAB/state/task.meta"
chmod 600 "$LAB/state/task.meta"
refuse 'not a no-mistakes task' "$ADAPTER" arm task
printf 'kind=ship\nmode=no-mistakes\nworktree=%s\n' "$LAB/wt" > "$LAB/state/task.meta"
printf '\nExisting merge monitor prevents CI ownership:\n'
touch "$LAB/state/task.check.sh"
refuse 'already has a PR/custom monitor' "$ADAPTER" arm task
rm "$LAB/state/task.check.sh"
printf '\nRegister a durable CI source without starting a pipeline:\n'
"$RUNNER" register ci ci-livecheck -- "$ADAPTER" poll task "$LAB/wt" LIVECHECK fm/ci "$PR"
"$RUNNER" list
printf '\nExisting CI ownership prevents both duplicate CI and merge monitoring:\n'
refuse 'CI wait already registered' "$ADAPTER" arm task
refuse 'delegated CI wait' bin/fm-pr-check.sh task "$PR"
printf '\nRestart the runner with a genuinely unavailable run in an empty isolated NM_HOME:\n'
"$RUNNER" ensure-listening ci-livecheck
for ((i=0;i<100;i++)); do
  captures=("$LAB/state/procevent-inbox/ci-livecheck."*.result)
  if [ -f "${captures[0]}" ] && [ -s "$LAB/state/.wake-queue" ]; then break; fi
  sleep .1
done
capture=${captures[0]}
test -f "$capture"
cat "$capture"
test "$("$ADAPTER" classify "$capture")" = monitor-error
printf '\nDurable wake:\n'
cat "$LAB/state/.wake-queue"
sequence=${capture##*/ci-livecheck.}
sequence=${sequence%.result}
printf '\nAcknowledge twice, then reconcile after retirement:\n'
"$RUNNER" handled ci-livecheck "$sequence"
"$RUNNER" handled ci-livecheck "$sequence"
before=$(wc -l < "$LAB/state/.wake-queue")
"$RUNNER" reconcile
test "$(wc -l < "$LAB/state/.wake-queue")" = "$before"
test ! -e "$LAB/state/procevent/ci-livecheck.source"
"$RUNNER" list
printf '\nNo new wake after acknowledgement; terminal CI source retired.\n'
