#!/usr/bin/env bash
# Pinned browser MCP server for workers: verify this machine's pins, then exec
# chrome-devtools-mcp on stdio. Nothing is fetched or installed at launch.
#
# Usage: fm-browser-mcp.sh <config-file>          verify pins, then serve on stdio
#        fm-browser-mcp.sh --check <config-file>  verify pins only and print ok
#
# <config-file> is a home's local, gitignored config/browser-mcp: one key=value
# per line; blank lines and lines starting with # are ignored. Keys:
#   mcp=<absolute path>      chrome-devtools-mcp's build/src/bin/chrome-devtools-mcp.js
#                            inside a dedicated, version-pinned install
#   mcp_sha256=<64 hex>      SHA-256 of that file
#   chrome=<absolute path>   Chrome for Testing executable
#   chrome_sha256=<64 hex>   SHA-256 of that executable
#   node=<absolute path>     optional Node.js executable; default node on PATH
# Any other key, a duplicate key, a relative or missing path, a non-executable
# browser, or a hash mismatch refuses with one readable line on stderr and exit 1,
# before anything starts.
#
# The server starts one isolated headless Chrome per server process: a throwaway
# profile that is deleted when the browser closes, and a pipe connection, so no
# debugging port is opened and concurrent workers never share a browser. Page
# tools act on the selected page (no page id required); new_page, select_page
# and list_pages manage it, and tool failures return MCP errors with the
# browser's message. Usage statistics and CrUX lookups are off.
# Lifetime: the harness owns this process over stdio. When the harness exits,
# stdin closes and the server exits; Chrome exits with it because its pipe
# closes, even if the server is killed. bin/fm-teardown.sh's
# stop_owned_browser_mcp is the backstop for a server left in a task copy.
#
# bin/fm-spawn.sh attaches this server to supported workers when the home has
# config/browser-mcp; docs/configuration.md "Browser MCP pin" owns setup and
# per-harness support.
set -eu

die() { echo "fm-browser-mcp: $*" >&2; exit 1; }

CHECK=0
if [ "${1:-}" = --check ]; then
  CHECK=1
  shift
fi
[ "$#" -eq 1 ] || die "usage: fm-browser-mcp.sh [--check] <config-file>"
CONFIG_FILE=$1
[ -f "$CONFIG_FILE" ] && [ -r "$CONFIG_FILE" ] || die "$CONFIG_FILE is not a readable regular file"

MCP='' MCP_SHA='' CHROME='' CHROME_SHA='' NODE='' SEEN=' '
while IFS= read -r line || [ -n "$line" ]; do
  case "$line" in ''|'#'*) continue ;; esac
  case "$line" in *=*) ;; *) die "$CONFIG_FILE: expected key=value, got: $line" ;; esac
  key=${line%%=*} value=${line#*=}
  case "$SEEN" in *" $key "*) die "$CONFIG_FILE: duplicate key $key" ;; esac
  SEEN="$SEEN$key "
  case "$key" in
    mcp) MCP=$value ;;
    mcp_sha256) MCP_SHA=$value ;;
    chrome) CHROME=$value ;;
    chrome_sha256) CHROME_SHA=$value ;;
    node) NODE=$value ;;
    *) die "$CONFIG_FILE: unknown key $key (accepted: mcp, mcp_sha256, chrome, chrome_sha256, node)" ;;
  esac
done < "$CONFIG_FILE"

if command -v sha256sum >/dev/null 2>&1; then
  sha256_of() { sha256sum -- "$1" | cut -d' ' -f1; }
elif command -v shasum >/dev/null 2>&1; then
  sha256_of() { shasum -a 256 -- "$1" | cut -d' ' -f1; }
else
  die "neither sha256sum nor shasum is available to verify the pins"
fi

pinned_file() {  # <key> <path> <sha-key> <expected-sha>
  case "$2" in /*) ;; '') die "$CONFIG_FILE: $1= is required" ;; *) die "$CONFIG_FILE: $1 must be an absolute path: $2" ;; esac
  [ -f "$2" ] || die "$CONFIG_FILE: $1 does not name a regular file: $2"
  printf '%s' "$4" | LC_ALL=C grep -Eqx '[0-9a-f]{64}' || die "$CONFIG_FILE: $3= must be 64 lowercase hex characters"
  actual=$(sha256_of "$2")
  [ "$actual" = "$4" ] || die "$1 $2 has SHA-256 $actual, not the pinned $3 $4; re-pin deliberately after verifying the update"
}

pinned_file mcp "$MCP" mcp_sha256 "$MCP_SHA"
pinned_file chrome "$CHROME" chrome_sha256 "$CHROME_SHA"
[ -x "$CHROME" ] || die "chrome $CHROME is not executable"
if [ -n "$NODE" ]; then
  case "$NODE" in /*) ;; *) die "$CONFIG_FILE: node must be an absolute path: $NODE" ;; esac
  [ -f "$NODE" ] && [ -x "$NODE" ] || die "node $NODE is not an executable file"
else
  NODE=$(command -v node) || die "node is not on PATH; install Node.js or set node= in $CONFIG_FILE"
fi

if [ "$CHECK" -eq 1 ]; then
  echo "ok: pinned chrome-devtools-mcp $MCP and Chrome $CHROME verified"
  exit 0
fi
exec "$NODE" "$MCP" --executablePath="$CHROME" --isolated --headless \
  --no-page-id-routing --no-usage-statistics --no-performance-crux
