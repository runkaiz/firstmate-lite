#!/usr/bin/env bash
# Live guard for bin/fm-browser-mcp.sh against this machine's real pins: the
# pinned server answers on stdio with selected-page routing and readable errors,
# carries the process title bin/fm-teardown.sh's stop_owned_browser_mcp
# recognizes, keeps its browser in the launch cwd, and takes the browser down
# when stdin closes. Spends no model tokens.
# Runs when FM_BROWSER_MCP_CONFIG names a config/browser-mcp file; skips without
# one unless FM_BROWSER_MCP_LIVE=1 or FM_LIVE=1 forces it.
set -u
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"
fm_live_gate default-on FM_BROWSER_MCP_LIVE node
CONFIG_FILE=${FM_BROWSER_MCP_CONFIG:-}
if [ -z "$CONFIG_FILE" ]; then
  if [ "${FM_BROWSER_MCP_LIVE:-}" = 1 ] || [ "${FM_LIVE:-}" = 1 ]; then
    fail 'live browser MCP guard was requested but FM_BROWSER_MCP_CONFIG names no pin file'
  fi
  printf 'skip: live: FM_BROWSER_MCP_CONFIG absent\n'
  exit 0
fi
if [ ! -d /proc/self ]; then
  printf 'skip: live: /proc absent; this guard reads process cwds from /proc\n'
  exit 0
fi
"$ROOT/bin/fm-browser-mcp.sh" --check "$CONFIG_FILE" || fail "pins in $CONFIG_FILE do not verify"
TMP_ROOT=$(fm_test_tmproot fm-browser-mcp-live)
WORK="$TMP_ROOT/copy"
mkdir -p "$WORK"
WORK=$(cd "$WORK" && pwd -P)

out=$(cd "$TMP_ROOT" && FM_LAUNCHER="$ROOT/bin/fm-browser-mcp.sh" FM_CONFIG_FILE="$CONFIG_FILE" FM_WORK="$WORK" \
  timeout 90 node --input-type=module 2>&1 <<'JS'
import {spawn, execFileSync} from 'node:child_process';
import fs from 'node:fs';
const {FM_LAUNCHER, FM_CONFIG_FILE, FM_WORK} = process.env;
const fail = m => { console.log(`FAIL ${m}`); process.exit(1); };
const inWork = () => fs.readdirSync('/proc').filter(x => /^\d+$/.test(x)).filter(x => {
  try { return fs.readlinkSync(`/proc/${x}/cwd`) === FM_WORK; } catch { return false; }
});
const server = spawn(FM_LAUNCHER, [FM_CONFIG_FILE], {cwd: FM_WORK, stdio: ['pipe', 'pipe', 'ignore']});
let buf = '', id = 0; const waiting = {};
server.stdout.on('data', d => {
  buf += d; let i;
  while ((i = buf.indexOf('\n')) >= 0) {
    const line = buf.slice(0, i); buf = buf.slice(i + 1);
    try { const m = JSON.parse(line); if (m.id && waiting[m.id]) waiting[m.id](m); } catch {}
  }
});
const rpc = (method, params) => new Promise(r => { const n = ++id; waiting[n] = r; server.stdin.write(JSON.stringify({jsonrpc: '2.0', id: n, method, params}) + '\n'); });
const text = r => (r.result?.content || []).map(c => c.text || '').join('\n');
await rpc('initialize', {protocolVersion: '2025-06-18', capabilities: {}, clientInfo: {name: 'fm-live-guard', version: '1'}});
server.stdin.write(JSON.stringify({jsonrpc: '2.0', method: 'notifications/initialized'}) + '\n');
let r = await rpc('tools/call', {name: 'navigate_page', arguments: {url: 'data:text/html,<title>FM live guard</title>'}});
if (r.result?.isError || !/FM live guard.*\[selected\]/.test(text(r))) fail(`navigate did not select the page: ${text(r)}`);
r = await rpc('tools/call', {name: 'evaluate_script', arguments: {function: '() => document.title'}});
if (r.result?.isError || !text(r).includes('"FM live guard"')) fail(`evaluate without a page id failed: ${text(r)}`);
r = await rpc('tools/call', {name: 'evaluate_script', arguments: {function: '() => { throw new Error("fm synthetic failure") }'}});
if (r.result?.isError !== true || !text(r).includes('fm synthetic failure')) fail(`a page error was not a readable MCP error: ${JSON.stringify(r.result)}`);
const title = execFileSync('ps', ['-p', String(server.pid), '-o', 'command=']).toString().trim();
if (!(title === 'chrome-devtools-mcp' || title.startsWith('chrome-devtools-mcp ') || title.includes('/chrome-devtools-mcp/'))) fail(`server command "${title}" is not what stop_owned_browser_mcp recognizes`);
const live = inWork();
if (live.length < 2) fail(`expected the server and its browser in the launch cwd, saw ${live.length} process(es)`);
server.stdin.end();
for (let i = 0; i < 40 && inWork().length; i++) await new Promise(res => setTimeout(res, 250));
if (inWork().length) fail(`processes outlived stdin close: ${inWork().join(' ')}`);
console.log(`OK title=${title} processes=${live.length}`);
JS
)
rc=$?
expect_code 0 "$rc" "live pinned browser MCP guard failed: $out"
assert_contains "$out" 'OK title=' "live guard did not complete: $out"
pass "pinned browser MCP serves selected-page tools, readable errors, a recognizable title, and exits with its browser on stdin close ($(printf '%s' "$out" | sed -n 's/^OK //p'))"
