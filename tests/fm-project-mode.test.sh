#!/usr/bin/env bash
# GitHub/local registry defaults and fail-closed refusal of removed forge bindings.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
PROJECT_MODE="$ROOT/bin/fm-project-mode.sh"
TMP_ROOT=$(fm_test_tmproot fm-project-mode-tests)
DATA="$TMP_ROOT/data"
mkdir -p "$DATA"
printf '%s\n' '- legacy - fixture' '- flagged [direct-PR +yolo] - fixture' '- local [local-only] - fixture' > "$DATA/projects.md"
for row in 'legacy|no-mistakes off' 'flagged|direct-PR on' 'local|local-only off'; do
  IFS='|' read -r project expected <<EOF
$row
EOF
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" "$project" 2>/dev/null)
  [ "$out" = "$expected" ] || fail "$project: expected $expected, got $out"
  out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" --forge "$project" 2>/dev/null)
  [ "$out" = none ] || fail "$project: unexpected forge $out"
done
pass "GitHub/local delivery keeps mode, merge authority and default forge"
for forge in gitlab gerrit forgejo gitea; do
  for mode in no-mistakes direct-PR local-only; do
    printf '%s\n' "- removed [$mode forge=$forge] - fixture" > "$DATA/projects.md"
    for flag in '' --forge --raw --retained-history; do
      # shellcheck disable=SC2086 # Empty flag intentionally emits no argument.
      out=$(FM_DATA_OVERRIDE="$DATA" "$PROJECT_MODE" $flag removed 2>"$TMP_ROOT/error"); rc=$?
      [ "$rc" -eq 3 ] || fail "$mode/$forge/$flag must refuse, got $rc"
      [ -z "$out" ] || fail "removed forge emitted usable posture: $out"
      assert_contains "$(cat "$TMP_ROOT/error")" 'only GitHub/local' "refusal must name supported delivery"
    done
  done
done
pass "removed forge bindings refuse without silently changing delivery"
out=$(FM_DATA_OVERRIDE="$TMP_ROOT/absent" "$PROJECT_MODE" --forge absent 2>/dev/null)
[ "$out" = none ] || fail "absent registry changed default forge"
pass "absent registry preserves default forge"
for directory in "$TMP_ROOT/absent" "$DATA"; do
  out=$(FM_DATA_OVERRIDE="$directory" "$PROJECT_MODE" --retained-history absent 2>/dev/null)
  [ "$out" = off ] || fail "absent project or registry implicitly enabled history retention"
done
pass "history retention requires an explicit registered annotation"
