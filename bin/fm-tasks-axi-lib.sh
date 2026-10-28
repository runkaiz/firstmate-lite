# shellcheck shell=bash
# Native queue selection shared by lifecycle and startup owners.
# Legacy filename/function spellings are source-compatible entry points only;
# every execution addresses the shipped Python standard-library backend.
# .tasks.toml and legacy environment pins remain compatibility inputs.
# No external tasks-axi executable, global config, install or version is used.
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

fm_tasks_axi_backend_from_toml() {  # <toml-path>
  local toml=$1
  [ -f "$toml" ] || return 1
  LC_ALL=C awk '
    function trim(value) {
      sub(/^[[:space:]]+/, "", value)
      sub(/[[:space:]]+$/, "", value)
      return value
    }
    BEGIN { root=1; found=0; single=sprintf("%c", 39) }
    {
      line=$0
      sub(/[[:space:]]*#.*/, "", line)
      line=trim(line)
      if (line ~ /^\[[^]]+\]$/) {
        root=0
        next
      }
      if (root && line ~ /^backend[[:space:]]*=/) {
        sub(/^backend[[:space:]]*=[[:space:]]*/, "", line)
        line=trim(line)
        if ((substr(line, 1, 1) == "\"" && substr(line, length(line), 1) == "\"") ||
            (substr(line, 1, 1) == single && substr(line, length(line), 1) == single)) {
          print substr(line, 2, length(line) - 2)
          found=1
          exit
        }
      }
    }
    END { if (!found) exit 1 }
  ' "$toml"
}

# Refuse unsupported legacy adapters before any caller derives an exemption.
fm_queue_backend_supported() {
  case "$1" in
    markdown) printf '%s\n' markdown ;;
    *) printf 'native queue supports Markdown only; configured backend %s requires an explicit compatible export before activation\n' "$1" >&2; return 2 ;;
  esac
}

# Native override, legacy override, then this root's compatibility configuration.
fm_tasks_axi_backend_resolve() {  # <tasks-axi-working-directory>
  local root=$1 backend
  if [ "${FM_QUEUE_BACKEND+x}" = x ]; then
    fm_queue_backend_supported "$FM_QUEUE_BACKEND"
    return $?
  fi
  if [ "${TASKS_AXI_BACKEND+x}" = x ]; then
    fm_queue_backend_supported "$TASKS_AXI_BACKEND"
    return $?
  fi
  local config="$root/.tasks.toml"
  if { [ -d "${config%/*}" ] && [ ! -x "${config%/*}" ]; } ||
    { { [ -e "$config" ] || [ -L "$config" ]; } && { [ ! -f "$config" ] || [ ! -r "$config" ]; }; }; then
    printf 'tasks-axi backend configuration cannot be read at %s\n' "$config" >&2
    return 2
  fi
  if backend=$(fm_tasks_axi_backend_from_toml "$config"); then
    fm_queue_backend_supported "$backend"
    return $?
  fi
  printf '%s\n' markdown
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
