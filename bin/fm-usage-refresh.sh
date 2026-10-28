#!/usr/bin/env bash
# Best-effort lifecycle attachment for bin/fm-usage-auto.py (its header owns CLI).
# No background process; automatic refresh is bounded, serialized, and throttled.
# Callers pass the resolved FM_HOME and any FM_*_OVERRIDE paths explicitly.
set -u
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[ -n "${FM_HOME:-}" ] || { echo "fm-usage-ledger: explicit FM_HOME required" >&2; exit 1; }
python3 "$SCRIPT_DIR/fm-usage-auto.py" refresh "$@" >/dev/null \
  || echo 'fm-usage-ledger: automatic refresh unavailable; inspect fm-usage-auto.py status (usage unknown)' >&2
