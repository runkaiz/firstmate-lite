#!/usr/bin/env bash
# bin/backends/herdr-remote.sh - the remote-worker session-provider adapter.
#
# A remote task's worker runs in a tab of another machine's Herdr server,
# reached through a saved Herdr machine profile (`herdr --machine <id>`), while
# every task record, the supervision loop, and landing stay on this machine.
# docs/remote-workers.md owns the operator contract; bin/fm-remote-task.sh owns
# provisioning, the courier, publication, and retirement.
#
# Opt-in: config/remote-machines lists each machine Firstmate may use, one per
# line: `<herdr-profile-id> <label> [<remote-root>]` (root defaults to
# ~/firstmate-remote; `#` starts a comment). Nothing is dispatched to a machine
# merely because Herdr knows it.
#
# Identity: a remote task records backend=herdr-remote and
# window=<profile-id>:<pane-id>, so a remote key can never equal a local
# `<session>:<pane-id>` key. The profile ids are exported in
# FM_BACKEND_HERDR_MACHINES, which makes bin/backends/herdr.sh route every
# call for such a "session" through `herdr --machine <id>` (bounded by
# FM_REMOTE_HERDR_TIMEOUT, default 15 s) and never start or probe a server.
# The read and input primitives below therefore reuse the Herdr adapter's
# response parsing unchanged, and replace exactly the parts that touch the
# local machine:
#   - process evidence comes from the remote machine's own process table, as
#     recorded by the courier in state/<id>.remote-procs, never from local ps;
#   - no signals at all: a remote pane closes only through Herdr's explicit
#     tab close, under the focus rule in fm_backend_herdr_remote_kill;
#   - no server start or restart, no push events, no presentation spaces.
# Every input or close first proves the pane still belongs to the task
# (fm_remote_identity_ok: the recorded server incarnation, or else the tab's
# launch-token label). Every primitive first reads the machine's link record,
# state/.remote-link-<profile-id> (written only by the courier). Anything but
# `reachable` makes liveness reads `unreadable`/`unknown` - never dead or
# missing - and refuses input, so an asleep or disconnected machine is never
# mistaken for a dead worker.

FM_BACKEND_HERDR_REMOTE_ROOT="$(d=${BASH_SOURCE[0]%/*}; [ "$d" != "${BASH_SOURCE[0]}" ] || d=.; cd "${d:-/}/../.." && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-${FM_ROOT:-$FM_BACKEND_HERDR_REMOTE_ROOT}}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"

if ! declare -F fm_backend_herdr_cli >/dev/null 2>&1; then
  # shellcheck source=bin/backends/herdr.sh
  . "$FM_BACKEND_HERDR_REMOTE_ROOT/bin/backends/herdr.sh"
fi

# shellcheck disable=SC2088 # a literal remote path, expanded on the remote host
FM_REMOTE_DEFAULT_ROOT='~/firstmate-remote'
# Seconds a courier process-row observation stays usable as liveness proof.
FM_REMOTE_PROCS_FRESH_SECS=${FM_REMOTE_PROCS_FRESH_SECS:-120}

fm_remote_config_dir() {
  printf '%s' "${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
}

fm_remote_state_dir() {
  printf '%s' "${FM_STATE_OVERRIDE:-$FM_HOME/state}"
}

# fm_remote_machine_lines: the valid configuration lines as
# "<id>\t<label>\t<root>", or nothing. A malformed line fails the whole read
# rather than being skipped, so a typo never silently drops a machine.
fm_remote_machine_lines() {  # [config-dir]
  local file line id label root extra
  file="${1:-$(fm_remote_config_dir)}/remote-machines"
  [ -e "$file" ] || return 0
  [ -f "$file" ] && [ ! -L "$file" ] || {
    echo "error: $file must be a regular file" >&2
    return 1
  }
  while IFS= read -r line || [ -n "$line" ]; do
    line=${line%%#*}
    # shellcheck disable=SC2086 # deliberate field splitting of one config line
    set -- $line
    [ "$#" -gt 0 ] || continue
    id=$1 label=${2:-} root=${3:-$FM_REMOTE_DEFAULT_ROOT} extra=${4:-}
    case "$id" in ''|*[!A-Za-z0-9._-]*) echo "error: $file: invalid machine id '$id'" >&2; return 1 ;; esac
    case "$label" in ''|*[!A-Za-z0-9._-]*) echo "error: $file: machine $id needs a plain label" >&2; return 1 ;; esac
    # shellcheck disable=SC2088 # literal remote-path forms, not local paths
    case "$root" in
      '~'|'~/'*|/*) ;;
      *) echo "error: $file: remote root for $label must be absolute or start with ~/" >&2; return 1 ;;
    esac
    case "$root" in *\'*|*\"*|*\\*|*\$*|*\`*) echo "error: $file: remote root for $label has shell metacharacters" >&2; return 1 ;; esac
    [ -z "$extra" ] || { echo "error: $file: too many fields for machine $label" >&2; return 1; }
    printf '%s\t%s\t%s\n' "$id" "$label" "$root"
  done < "$file"
}

# fm_remote_machine_lookup: resolve <label-or-id> to exactly one configured
# machine, setting FM_REMOTE_MACHINE_ID, FM_REMOTE_MACHINE_LABEL and
# FM_REMOTE_MACHINE_ROOT.
fm_remote_machine_lookup() {  # <label-or-id> [config-dir]
  local want=$1 lines id label root matches=0
  # shellcheck disable=SC2034 # outputs for sourcing callers
  FM_REMOTE_MACHINE_ID='' FM_REMOTE_MACHINE_LABEL='' FM_REMOTE_MACHINE_ROOT=''
  lines=$(fm_remote_machine_lines "${2:-}") || return 1
  while IFS=$'\t' read -r id label root; do
    [ -n "$id" ] || continue
    if [ "$want" = "$id" ] || [ "$want" = "$label" ]; then
      matches=$((matches + 1))
      FM_REMOTE_MACHINE_ID=$id FM_REMOTE_MACHINE_LABEL=$label FM_REMOTE_MACHINE_ROOT=$root
    fi
  done <<< "$lines"
  if [ "$matches" -ne 1 ]; then
    # shellcheck disable=SC2034 # outputs for sourcing callers
    FM_REMOTE_MACHINE_ID='' FM_REMOTE_MACHINE_LABEL='' FM_REMOTE_MACHINE_ROOT=''
    echo "error: machine '$want' is not configured exactly once in $(fm_remote_config_dir "${2:-}")/remote-machines" >&2
    return 1
  fi
}

fm_remote_machine_ids() {  # [config-dir]
  fm_remote_machine_lines "${1:-}" 2>/dev/null | cut -f1
}

# Export the configured profile ids so bin/backends/herdr.sh routes them.
FM_BACKEND_HERDR_MACHINES=$(fm_remote_machine_ids | tr '\n' ' ')
export FM_BACKEND_HERDR_MACHINES

# fm_remote_profile_binding: re-check a profile against Herdr's own saved
# machine list before any mutation. Prints "<target>\t<session>" only when
# exactly one enabled profile has this id and label.
fm_remote_profile_binding() {  # <profile-id> <label>
  local id=$1 label=$2 out row
  out=$(fm_run_timed 10 herdr machine list --json 2>/dev/null) || {
    echo "error: herdr machine list failed; refusing a remote mutation without a verified profile" >&2
    return 1
  }
  row=$(printf '%s' "$out" | jq -r --arg id "$id" --arg label "$label" '
    [ .[] | select(.id == $id) ] as $m
    | if ($m | length) == 1 and $m[0].label == $label and $m[0].enabled == true
        and ($m[0].target | type) == "string" and ($m[0].session | type) == "string"
      then "\($m[0].target)\t\($m[0].session)" else empty end' 2>/dev/null) || row=
  [ -n "$row" ] || {
    echo "error: Herdr profile $id is not exactly one enabled machine labeled '$label'; refusing" >&2
    return 1
  }
  printf '%s\n' "$row"
}

# fm_remote_ssh: run the script on stdin on <target> under /bin/bash, with
# connect and keepalive bounds plus an overall timeout. FM_REMOTE_SSH replaces
# the ssh binary (portable tests use a stand-in). Never forwards an agent.
fm_remote_ssh() {  # <target> [timeout-seconds]
  local target=$1 secs=${2:-${FM_REMOTE_SSH_TIMEOUT:-15}}
  case "$target" in ''|-*|*[[:space:]]*) echo "error: invalid ssh target '$target'" >&2; return 1 ;; esac
  fm_run_timed "$secs" "${FM_REMOTE_SSH:-ssh}" -o BatchMode=yes -o ConnectTimeout=5 \
    -o ServerAliveInterval=5 -o ServerAliveCountMax=2 -o ForwardAgent=no \
    -o ClearAllForwardings=yes "$target" '/bin/bash -s'
}

# --- link record -------------------------------------------------------------
# state/.remote-link-<id>: state=<reachable|unreachable|herdr-unavailable>,
# since=<epoch the state began>, last_ok=<epoch>, reason=<text>.

fm_remote_link_file() {  # <state-dir> <machine-id>
  printf '%s/.remote-link-%s' "$1" "$2"
}

fm_remote_link_state() {  # <state-dir> <machine-id> -> reachable|unreachable|herdr-unavailable|unknown
  local v
  v=$(fm_meta_get "$(fm_remote_link_file "$1" "$2")" state 2>/dev/null) || v=
  printf '%s' "${v:-unknown}"
}

fm_remote_link_reachable() {  # <state-dir> <machine-id>
  [ "$(fm_remote_link_state "$1" "$2")" = reachable ]
}

# --- task records ------------------------------------------------------------

# fm_remote_record_set: atomically replace or add key=value pairs in a
# key=value record, keeping every other line.
fm_remote_record_set() {  # <record> <key=value>...
  local rec=$1 tmp pair key
  shift
  tmp=$(mktemp "${rec%/*}/.${rec##*/}.XXXXXX") || return 1
  {
    [ ! -f "$rec" ] || awk -v keys="$(for pair in "$@"; do printf '%s ' "${pair%%=*}"; done)" '
      BEGIN { n = split(keys, k, " "); for (i = 1; i <= n; i++) drop[k[i]] = 1 }
      { split($0, f, "="); if (!(f[1] in drop)) print }
    ' "$rec"
    for pair in "$@"; do
      key=${pair%%=*}
      case "$key" in ''|*[!A-Za-z0-9_]*) return 1 ;; esac
      case "$pair" in *$'\n'*) return 1 ;; esac
      printf '%s\n' "$pair"
    done
  } > "$tmp" || { rm -f -- "$tmp"; return 1; }
  mv -f -- "$tmp" "$rec" || { rm -f -- "$tmp"; return 1; }
}

# fm_remote_task_of_target: the task id whose meta records <target>.
fm_remote_task_of_target() {  # <target>
  local meta state
  state=$(fm_remote_state_dir)
  meta=$(fm_backend_meta_for_window "$1" "$state" 2>/dev/null) || return 1
  [ -n "$meta" ] || return 1
  meta=${meta##*/}
  printf '%s' "${meta%.meta}"
}

# fm_remote_target_reachable: parse <target> and require a reachable link.
fm_remote_target_reachable() {  # <target>
  fm_backend_herdr_parse_target "$1" || return 1
  fm_backend_herdr_is_machine "$FM_BACKEND_HERDR_SESSION" || return 1
  fm_remote_link_reachable "$(fm_remote_state_dir)" "$FM_BACKEND_HERDR_SESSION"
}

# fm_remote_procs_verdict: the courier's latest remote process observation for
# <task>: agent (a Claude process descends from the pane shell), shell (the
# pane shell is alive with no Claude descendant), or unknown (absent, stale, or
# the shell is gone or unreadable).
fm_remote_procs_verdict() {  # <task>
  local rec observed shell agent now
  rec="$(fm_remote_state_dir)/$1.remote-procs"
  [ -f "$rec" ] || { printf 'unknown'; return 0; }
  observed=$(fm_meta_get "$rec" observed)
  shell=$(fm_meta_get "$rec" shell)
  agent=$(fm_meta_get "$rec" agents)
  now=$(date +%s)
  case "$observed" in ''|*[!0-9]*) printf 'unknown'; return 0 ;; esac
  [ $((now - observed)) -le "$FM_REMOTE_PROCS_FRESH_SECS" ] || { printf 'unknown'; return 0; }
  case "$shell:$agent" in
    alive:0) printf 'shell' ;;
    alive:[1-9]*) printf 'agent' ;;
    *) printf 'unknown' ;;
  esac
}

# --- backend primitives (dispatched from bin/fm-backend.sh) -----------------

fm_backend_herdr_remote_capture() {  # <target> <lines> [label]
  fm_remote_target_reachable "$1" || return 1
  fm_backend_herdr_capture "$1" "$2"
}

fm_backend_herdr_remote_visible_capture() {  # <target> [label]
  fm_remote_target_reachable "$1" || return 1
  fm_backend_herdr_visible_capture "$1"
}

fm_backend_herdr_remote_send_key() {  # <target> <key> [label]
  fm_remote_target_reachable "$1" && fm_remote_identity_ok "$1" || return 1
  fm_backend_herdr_send_key "$1" "$2"
}

fm_backend_herdr_remote_send_text_submit() {  # <target> <text> <retries> <enter-sleep> <settle> [label]
  { fm_remote_target_reachable "$1" && fm_remote_identity_ok "$1"; } || { printf 'send-failed'; return 0; }
  fm_backend_herdr_send_text_submit "$1" "$2" "$3" "$4" "$5"
}

fm_backend_herdr_remote_composer_state() {  # <target> [label]
  fm_remote_target_reachable "$1" || { printf 'unknown'; return 0; }
  fm_backend_herdr_composer_state "$1"
}

# Herdr's own agent status, demoted to unknown unless the remote process rows
# still show a process under the pane shell.
fm_backend_herdr_remote_busy_state() {  # <target>
  local verdict task
  fm_remote_target_reachable "$1" || { printf 'unknown'; return 0; }
  verdict=$(fm_backend_herdr_classify_agent_status \
    "$(fm_backend_herdr_agent_status_raw "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")")
  if [ "$verdict" = busy ]; then
    task=$(fm_remote_task_of_target "$1") || task=
    [ -n "$task" ] && [ "$(fm_remote_procs_verdict "$task")" = agent ] || verdict=unknown
  fi
  printf '%s' "$verdict"
}

fm_backend_herdr_remote_target_exists() {  # <target>
  fm_remote_target_reachable "$1" || return 1
  [ "$(fm_backend_herdr_pane_presence_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" = present ]
}

# fm_backend_herdr_remote_agent_state: the recovery-grade vocabulary of
# fm_backend_agent_state. An unreachable machine is `unreadable`, never dead or
# missing. A reachable machine reports `missing` only on Herdr's structured
# pane_not_found, and `dead` only when fresh remote process rows show the pane
# shell alive with no Claude process below it.
fm_backend_herdr_remote_agent_state() {  # <target>
  local task presence procs
  fm_remote_target_reachable "$1" || { printf 'unreadable'; return 0; }
  presence=$(fm_backend_herdr_pane_presence_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")
  case "$presence" in
    dead) printf 'missing'; return 0 ;;
    present) ;;
    *) printf 'unreadable'; return 0 ;;
  esac
  task=$(fm_remote_task_of_target "$1") || task=
  [ -n "$task" ] || { printf 'ambiguous'; return 0; }
  procs=$(fm_remote_procs_verdict "$task")
  case "$procs" in
    agent) printf 'alive' ;;
    shell) printf 'dead' ;;
    *) printf 'unreadable' ;;
  esac
}

# fm_remote_focus_snapshot: "<focused-workspace>\t<focused-tab-of-it>" for the
# machine, or failure when focus cannot be read.
fm_remote_focus_snapshot() {  # <machine-id>
  local m=$1 ws tab out
  out=$(fm_backend_herdr_cli "$m" workspace list 2>/dev/null) || return 1
  ws=$(printf '%s' "$out" | jq -r '[.result.workspaces[] | select(.focused == true)] | if length == 1 then .[0].workspace_id else empty end' 2>/dev/null) || ws=
  [ -n "$ws" ] || return 1
  out=$(fm_backend_herdr_cli "$m" tab list --workspace "$ws" 2>/dev/null) || return 1
  tab=$(printf '%s' "$out" | jq -r '[.result.tabs[] | select(.focused == true)] | if length == 1 then .[0].tab_id else empty end' 2>/dev/null) || tab=
  [ -n "$tab" ] || return 1
  printf '%s\t%s\n' "$ws" "$tab"
}

# fm_remote_tab_count: number of tabs in <workspace>, or failure.
fm_remote_tab_count() {  # <machine-id> <workspace>
  local out
  out=$(fm_backend_herdr_cli "$1" tab list --workspace "$2" 2>/dev/null) || return 1
  printf '%s' "$out" | jq -er '.result.tabs | length' 2>/dev/null
}

# fm_remote_identity_ok: before any mutation of <target>, prove the pane still
# belongs to this task. While the remote server's incarnation (recorded by the
# courier in the link record) equals the one recorded at create, the recorded
# ids stand. After a change, or when either is unknown, the recorded tab must
# still carry this task's launch-token label; a match re-binds the incarnation.
fm_remote_identity_ok() {  # <target>
  local target=$1 task meta rec now_inc was_inc tab ws label have state
  fm_backend_herdr_parse_target "$target" || return 1
  task=$(fm_remote_task_of_target "$target") || return 1
  state=$(fm_remote_state_dir)
  meta="$state/$task.meta" rec="$state/$task.remote"
  now_inc=$(fm_meta_get "$(fm_remote_link_file "$state" "$FM_BACKEND_HERDR_SESSION")" incarnation)
  was_inc=$(fm_meta_get "$rec" incarnation)
  if [ -n "$now_inc" ] && [ "$now_inc" != unknown ] && [ "$now_inc" = "$was_inc" ]; then
    return 0
  fi
  tab=$(fm_meta_get "$meta" herdr_tab_id)
  ws=$(fm_meta_get "$meta" herdr_workspace_id)
  label=$(fm_meta_get "$rec" tab_label)
  [ -n "$tab" ] && [ -n "$ws" ] && [ -n "$label" ] || return 1
  have=$(fm_backend_herdr_cli "$FM_BACKEND_HERDR_SESSION" tab list --workspace "$ws" 2>/dev/null \
    | jq -r --arg t "$tab" '.result.tabs[] | select(.tab_id == $t) | .label' 2>/dev/null) || have=
  [ "$have" = "$label" ] || {
    echo "error: remote tab $tab no longer carries launch token $label (server incarnation ${was_inc:-unknown} -> ${now_inc:-unknown})" >&2
    return 1
  }
  [ -z "$now_inc" ] || [ "$now_inc" = unknown ] || fm_remote_record_set "$rec" "incarnation=$now_inc"
}

# fm_backend_herdr_remote_kill: close the exact recorded tab under the focus
# rule. Deferred (status 1, nothing closed) when focus cannot be read, when the
# tab is the focused tab of the focused workspace, or when closing it would
# empty the focused workspace; there is no plain-close fallback. An already-gone
# pane returns 0. The pane must still belong to the recorded tab.
fm_backend_herdr_remote_kill() {  # <target>
  local target=$1 m pane task meta tab ws presence focus fws ftab count out ptab after
  fm_remote_target_reachable "$target" || {
    echo "error: remote machine for $target is not reachable; nothing closed" >&2
    return 1
  }
  m=$FM_BACKEND_HERDR_SESSION pane=$FM_BACKEND_HERDR_PANE
  presence=$(fm_backend_herdr_pane_presence_state "$m" "$pane")
  [ "$presence" != dead ] || return 0
  [ "$presence" = present ] || { echo "error: remote pane $target presence is unreadable; nothing closed" >&2; return 1; }
  task=$(fm_remote_task_of_target "$target") || task=
  meta="$(fm_remote_state_dir)/$task.meta"
  [ -n "$task" ] && [ -f "$meta" ] || { echo "error: no task record names $target; nothing closed" >&2; return 1; }
  tab=$(fm_meta_get "$meta" herdr_tab_id)
  ws=$(fm_meta_get "$meta" herdr_workspace_id)
  out=$(fm_backend_herdr_cli "$m" pane get "$pane" 2>/dev/null) || out=
  ptab=$(printf '%s' "$out" | jq -r '.result.pane.tab_id // empty' 2>/dev/null) || ptab=
  [ -n "$tab" ] && [ "$ptab" = "$tab" ] || {
    echo "error: remote pane $target no longer belongs to recorded tab ${tab:-?}; nothing closed" >&2
    return 1
  }
  fm_remote_identity_ok "$target" || { echo "error: remote pane $target identity is unproven; nothing closed" >&2; return 1; }
  focus=$(fm_remote_focus_snapshot "$m") || {
    echo "notice: focus on the remote machine cannot be read; deferring the close of $target" >&2
    return 1
  }
  fws=${focus%%$'\t'*} ftab=${focus#*$'\t'}
  if [ "$ftab" = "$tab" ]; then
    echo "notice: $target is the focused tab on the remote machine; deferring its close" >&2
    return 1
  fi
  if [ "$fws" = "$ws" ]; then
    count=$(fm_remote_tab_count "$m" "$ws") || count=
    case "$count" in
      ''|*[!0-9]*|0|1) echo "notice: closing $target would empty the focused remote workspace; deferring" >&2; return 1 ;;
    esac
  fi
  fm_backend_herdr_cli "$m" tab close "$tab" >/dev/null 2>&1 || true
  presence=$(fm_backend_herdr_pane_presence_state "$m" "$pane")
  [ "$presence" = dead ] || { echo "error: remote pane $target is not confirmed gone after its close" >&2; return 1; }
  if after=$(fm_remote_focus_snapshot "$m") && [ "$after" != "$focus" ]; then
    echo "warning: remote focus changed during the close of $target (before ${focus//$'\t'/ }, after ${after//$'\t'/ }); left as is" >&2
  fi
  return 0
}

fm_backend_herdr_remote_endpoint_confirmed_gone() {  # <target>
  fm_remote_target_reachable "$1" || return 1
  [ "$(fm_backend_herdr_pane_presence_state "$FM_BACKEND_HERDR_SESSION" "$FM_BACKEND_HERDR_PANE")" = dead ]
}
