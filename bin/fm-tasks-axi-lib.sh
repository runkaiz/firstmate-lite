# shellcheck shell=bash
# Native queue selection shared by lifecycle and startup owners.
# Legacy filename/function spellings are source-compatible entry points only;
# every execution addresses the shipped Python standard-library backend.
# .tasks.toml and legacy environment pins remain compatibility inputs.
# No external tasks-axi executable, install or version is used.
# config/backlog-backend=manual retains the existing manual transition opt-out.
# Native Markdown compatibility/backup mechanics are owned by fm-queue.py.

# Isolated test fixtures can supply a command double; normal execution always
# uses the shipped backend, without PATH discovery or an external fallback.
FM_QUEUE_CLI="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/fm-queue.py"
if [ "${FM_TEST_SEAM:-0}" = 1 ] && [ -n "${FM_QUEUE_TEST_CLI:-}" ]; then
  FM_QUEUE_CLI=$FM_QUEUE_TEST_CLI
fi
FM_TASKS_AXI_MIN=1.0.0
FM_TASKS_AXI_COMPATIBLE_MEMO=${FM_TASKS_AXI_COMPATIBLE:-}
unset FM_TASKS_AXI_COMPATIBLE

fm_tasks_axi_version_parts() {
  "$FM_QUEUE_CLI" --version | tr . ' '
}

fm_tasks_axi_compatible() {
  command -v python3 >/dev/null 2>&1 && [ -x "$FM_QUEUE_CLI" ] \
    && python3 -c 'import sys; sys.exit(sys.version_info < (3, 9))'
}

fm_tasks_axi_compatible_probe() { fm_tasks_axi_compatible; }
fm_tasks_axi_update_has_archive_body() { fm_tasks_axi_compatible; }
fm_tasks_axi_mv_has_multi_id() { fm_tasks_axi_compatible; }

fm_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  python3 - "$1" "$(dirname "${BASH_SOURCE[0]}")/fm-queue.py" <<'PYTHON'
import runpy
import sys
from pathlib import Path

queue = runpy.run_path(sys.argv[2])
try:
    print(queue["resolve_backend"](Path(sys.argv[1]) / ".tasks.toml"))
except (queue["QueueError"], OSError, UnicodeError) as error:
    print(str(error), file=sys.stderr)
    sys.exit(2)
PYTHON
}

fm_tasks_axi_backend() {  # <tasks-axi-working-directory>
  fm_tasks_axi_backend_resolve "$1"
}

fm_backlog_backend_value() {
  local config_dir=$1 backend_file value
  backend_file="$config_dir/backlog-backend"
  if [ -f "$backend_file" ]; then
    value=$(tr -d '[:space:]' < "$backend_file" 2>/dev/null || true)
    [ -n "$value" ] || value=native
    printf '%s\n' "$value"
    return 0
  fi
  printf '%s\n' native
}

fm_backlog_backend_manual() {
  local config_dir=$1
  [ "$(fm_backlog_backend_value "$config_dir")" = manual ]
}

fm_tasks_axi_backend_available() {
  local config_dir=$1
  fm_backlog_backend_manual "$config_dir" && return 1
  fm_tasks_axi_compatible
}
