#!/usr/bin/env bash
# Deprecated compatibility entry point; the native queue owns all operations.
# Usage: fm-tasks-axi.sh [<native queue command> [args...]]
# No external tasks-axi executable is invoked.
set -eu
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
exec "$SCRIPT_DIR/fm-queue.sh" "$@"
