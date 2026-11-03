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

# --ci-workflows reads the clone's origin; the fake forge applies the script's real filter.
FAKEBIN=$(fm_fakebin "$TMP_ROOT/fake")
cat > "$FAKEBIN/gh" <<'SH'
#!/usr/bin/env bash
printf '%s\n' "$2" >> "$GH_CALLS"
[ -f "$WORKFLOWS" ] || exit 1
exec jq -r "$4" "$WORKFLOWS"
SH
chmod +x "$FAKEBIN/gh"
export GH_CALLS="$TMP_ROOT/gh-calls" WORKFLOWS="$TMP_ROOT/workflows.json"
PROJECTS="$TMP_ROOT/projects"
git init -q "$PROJECTS/app"
git -C "$PROJECTS/app" remote add origin git@github.com:acme/app.git
ci_query() { PATH="$FAKEBIN:$PATH" FM_DATA_OVERRIDE="$DATA" FM_PROJECTS_OVERRIDE="$PROJECTS" "$PROJECT_MODE" --ci-workflows "$1"; }
for row in \
  'none|{"workflows":[]}' \
  'none|{"workflows":[{"state":"active","path":"dynamic/dependabot/dependabot-updates"}]}' \
  'none|{"workflows":[{"state":"disabled_manually","path":".github/workflows/ci.yml"}]}' \
  'present|{"workflows":[{"state":"active","path":".github/workflows/ci.yml"}]}'; do
  printf '%s\n' "${row#*|}" > "$WORKFLOWS"
  out=$(ci_query app)
  [ "$out" = "${row%%|*}" ] || fail "workflow check for ${row#*|}: got $out"
done
pass "workflow check counts only active repository workflows"
assert_contains "$(cat "$GH_CALLS")" 'repos/acme/app/actions/workflows' "workflow check must read the origin's repository"
for origin in https://github.com/acme/app.git https://github.com/acme/app ssh://git@github.com/acme/app.git; do
  git -C "$PROJECTS/app" remote set-url origin "$origin"
  : > "$GH_CALLS"
  [ "$(ci_query app)" = present ] || fail "workflow check rejected $origin"
  [ "$(cat "$GH_CALLS")" = repos/acme/app/actions/workflows ] || fail "wrong repository for $origin"
done
pass "workflow check accepts every GitHub origin form"
rm -f "$WORKFLOWS"
[ "$(ci_query app)" = unknown ] || fail "a failed forge read must not read as no workflows"
printf '%s\n' '{"workflows":[]}' > "$WORKFLOWS"
git -C "$PROJECTS/app" remote set-url origin https://gitlab.com/acme/app.git
: > "$GH_CALLS"
[ "$(ci_query app)" = unknown ] || fail "a non-GitHub origin must not read as no workflows"
[ ! -s "$GH_CALLS" ] || fail "a non-GitHub origin must not reach GitHub"
[ "$(ci_query absent)" = unknown ] || fail "a missing clone must not read as no workflows"
pass "workflow check reports unknown rather than none when it has no answer"
