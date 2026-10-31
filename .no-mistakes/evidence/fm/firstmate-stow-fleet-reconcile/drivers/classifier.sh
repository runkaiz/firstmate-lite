#!/usr/bin/env bash
source .test-live/common-classifier.sh
classify() {
  expected=$1; shift
  before=$(fingerprint)
  out=$(bash bin/fm-reconcile-underway.sh "$@")
  printf '%s\n' "$out"
  check test "$(printf '%s\n' "$out" | cut -f2)" = "$expected"
  check test "$(fingerprint)" = "$before"
}
case_home generated
mkdir -p "$WT/build" "$WT/notes"
printf 'generated\n' > "$WT/build/output"
printf 'user evidence\n' > "$WT/notes/evidence"
classify landed
check test "$(printf '%s\n' "$out" | cut -f3)" = 'bin/fm-teardown.sh generated --preserve-untracked build'
printf '%s\n' "$out" | grep -F 'other leftovers refuse teardown: notes'

case_home unknown-pr
sed -i 's/^mode=local-only$/mode=direct-PR/' "$FM_HOME/state/$ID.meta"
printf 'pr=https://github.com/runkaiz/firstmate-lite/pull/999999999\n' >> "$FM_HOME/state/$ID.meta"
classify unknown
check test "$(printf '%s\n' "$out" | cut -f3)" = -

case_home merged-pr
sed -i 's/^mode=local-only$/mode=direct-PR/' "$FM_HOME/state/$ID.meta"
printf 'pr=https://github.com/runkaiz/firstmate-lite/pull/13\n' >> "$FM_HOME/state/$ID.meta"
classify landed
check test "$(printf '%s\n' "$out" | cut -f3)" = 'bin/fm-teardown.sh merged-pr'

case_home no-archive scout
rm "$FM_HOME/state/$ID.meta"
classify unretirable
mkdir -p "$FM_HOME/data/$ID"
printf '# Draft\n' > "$FM_HOME/data/$ID/report.md"
classify needs-captain
check test "$(printf '%s\n' "$out" | cut -f3)" = -

case_home archive-tamper scout
mkdir "$CASE/archive"
mv "$FM_HOME/state/$ID.meta" "$CASE/archive/$ID.meta"
classify record-archived --archive "$CASE/archive"
if bash bin/fm-task-record-restore.sh "$ID" "$CASE/archive/$ID.meta" "$(printf '%064d' 0)" "s1.$ID" "fm-lab:fm-$ID"; then exit 1; fi
check test ! -e "$FM_HOME/state/$ID.meta"
check test -d "$WT"
check test -f "$FM_HOME/state/$ID.git-worktree"
mkdir "$CASE/duplicate"
cp "$CASE/archive/$ID.meta" "$CASE/duplicate/$ID.meta"
classify unretirable --archive "$CASE/archive" --archive "$CASE/duplicate"
echo 'SCENARIO PASS: read-only reconciliation checks real forge state, flags evidence leftovers, refuses ambiguous archives and unverified reports; tampered archive cannot restore'
