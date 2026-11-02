#!/usr/bin/env bash
# bin/fm-browser-mcp.sh: pinned launch, readable refusals, and no network fetch.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
LAUNCHER="$ROOT/bin/fm-browser-mcp.sh"
TMP_ROOT=$(fm_test_tmproot fm-browser-mcp-tests)

sha() { if command -v sha256sum >/dev/null 2>&1; then sha256sum -- "$1" | cut -d' ' -f1; else shasum -a 256 -- "$1" | cut -d' ' -f1; fi; }

# A fixture MCP entry, browser and node. The fake node records its argv and cwd
# instead of serving, so the exec contract is observable without a browser.
FIX="$TMP_ROOT/fixture"
mkdir -p "$FIX/pkg/build/src/bin" "$FIX/chrome" "$FIX/work"
MCP="$FIX/pkg/build/src/bin/chrome-devtools-mcp.js"
CHROME="$FIX/chrome/chrome"
NODE="$FIX/node"
printf '// fixture entry\n' > "$MCP"
printf '#!/bin/sh\nexit 0\n' > "$CHROME"
chmod +x "$CHROME"
cat > "$NODE" <<'SH'
#!/usr/bin/env bash
{ printf 'cwd=%s\n' "$PWD"; printf 'arg=%s\n' "$@"; } > "$FM_TEST_NODE_LOG"
SH
chmod +x "$NODE"
CFG="$TMP_ROOT/browser-mcp"
write_cfg() { printf '%s\n' "$@" > "$CFG"; }
good_cfg() {
  write_cfg '# pinned per machine' "mcp=$MCP" "mcp_sha256=$(sha "$MCP")" '' \
    "chrome=$CHROME" "chrome_sha256=$(sha "$CHROME")" "node=$NODE" "$@"
}

good_cfg
out=$("$LAUNCHER" --check "$CFG" 2>&1)
expect_code 0 $? "a verified pin set must pass --check: $out"
assert_contains "$out" "ok: pinned chrome-devtools-mcp $MCP and Chrome $CHROME verified" '--check did not report the verified pins'
pass 'a complete, matching pin set verifies'

LOG="$TMP_ROOT/node.log"
out=$(cd "$FIX/work" && FM_TEST_NODE_LOG="$LOG" "$LAUNCHER" "$CFG" 2>&1)
expect_code 0 $? "launch failed: $out"
expected="cwd=$(cd "$FIX/work" && pwd)
arg=$MCP
arg=--executablePath=$CHROME
arg=--isolated
arg=--headless
arg=--no-page-id-routing
arg=--no-usage-statistics
arg=--no-performance-crux"
[ "$(cat "$LOG")" = "$expected" ] || fail "launch did not exec the pinned server with the isolated headless contract from the caller's cwd: $(cat "$LOG")"
pass 'launch execs the pinned entry with an isolated headless browser, selected-page routing and telemetry off'

# PATH node is used only when node= is absent; npx is never consulted.
fakebin=$(fm_fakebin "$TMP_ROOT/path")
cp "$NODE" "$fakebin/node"
printf '#!/bin/sh\necho npx-called >> "%s"\nexit 1\n' "$TMP_ROOT/npx.log" > "$fakebin/npx"
chmod +x "$fakebin/npx"
write_cfg "mcp=$MCP" "mcp_sha256=$(sha "$MCP")" "chrome=$CHROME" "chrome_sha256=$(sha "$CHROME")"
rm -f "$LOG"
out=$(PATH="$fakebin:$PATH" FM_TEST_NODE_LOG="$LOG" "$LAUNCHER" "$CFG" 2>&1)
expect_code 0 $? "launch with node from PATH failed: $out"
assert_contains "$(cat "$LOG")" "arg=$MCP" 'PATH node did not receive the pinned entry'
[ ! -e "$TMP_ROOT/npx.log" ] || fail 'the launcher consulted npx'
pass 'without node= the launcher uses node from PATH and never npx'

refuse() {  # <expected-stderr-fragment> <label>
  local out rc
  rm -f "$LOG"
  out=$(FM_TEST_NODE_LOG="$LOG" "$LAUNCHER" "$CFG" 2>&1); rc=$?
  expect_code 1 "$rc" "$2 must refuse"
  assert_contains "$out" "$1" "$2 refused without naming the problem"
  case "$out" in "fm-browser-mcp: "*) ;; *) fail "$2 refusal is not one attributed line: $out" ;; esac
  [ ! -e "$LOG" ] || fail "$2 still started the server"
  out=$("$LAUNCHER" --check "$CFG" 2>&1); rc=$?
  expect_code 1 "$rc" "$2 must fail --check"
}

good_cfg 'mcp_sha256=0000000000000000000000000000000000000000000000000000000000000000'
refuse 'duplicate key mcp_sha256' 'a duplicate key'
write_cfg "mcp=$MCP" "mcp_sha256=$(sha "$MCP" | tr '0-9a-f' '1-9a-f0')" "chrome=$CHROME" "chrome_sha256=$(sha "$CHROME")" "node=$NODE"
refuse "mcp $MCP has SHA-256 $(sha "$MCP"), not the pinned mcp_sha256" 'a drifted MCP entry'
write_cfg "mcp=$MCP" "mcp_sha256=$(sha "$MCP")" "chrome=$CHROME" "chrome_sha256=$(sha "$MCP")" "node=$NODE"
refuse "chrome $CHROME has SHA-256" 'a drifted browser'
good_cfg 'port=9222'
refuse 'unknown key port' 'an unknown key'
write_cfg "mcp=pkg/chrome-devtools-mcp.js" "mcp_sha256=$(sha "$MCP")" "chrome=$CHROME" "chrome_sha256=$(sha "$CHROME")"
refuse 'mcp must be an absolute path' 'a relative entry path'
write_cfg "mcp_sha256=$(sha "$MCP")" "chrome=$CHROME" "chrome_sha256=$(sha "$CHROME")"
refuse 'mcp= is required' 'a missing entry'
write_cfg "mcp=$MCP" "mcp_sha256=$(sha "$MCP" | tr 'a-f' 'A-F')" "chrome=$CHROME" "chrome_sha256=$(sha "$CHROME")"
refuse 'mcp_sha256= must be 64 lowercase hex characters' 'a malformed hash'
chmod -x "$CHROME"
good_cfg
refuse "chrome $CHROME is not executable" 'a non-executable browser'
chmod +x "$CHROME"
good_cfg 'just text'
refuse 'expected key=value' 'a line without a key'
out=$("$LAUNCHER" --check "$TMP_ROOT/absent" 2>&1)
expect_code 1 $? 'an absent config must refuse'
assert_contains "$out" 'is not a readable regular file' 'absent config refused for the wrong reason'
pass 'drifted, malformed, incomplete or unreadable pins refuse with a readable line before anything starts'
