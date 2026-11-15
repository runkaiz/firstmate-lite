#!/usr/bin/env bash
# fm-resource-lock.sh - machine-local resource locks for heavy commands.
#
# A machine has a few resources that only so many jobs can use at once: memory
# for a full test suite, a GPU, a device. A worker that needs one takes a slot
# itself, by running the heavy command through this script, instead of asking
# firstmate; resource admission counts heavy jobs rather than workers.
#
# Usage:
#   fm-resource-lock.sh run [--file <declaration>] <resource> -- <command> [arg...]
#   fm-resource-lock.sh brief
#
# run    Wait until <resource> has a free slot, then replace this process with
#        <command> while holding it. The exit status is the command's own. One
#        `resource-lock:` line on stderr reports a wait, and one the slot taken.
#        The slot frees when the command and any child processes retaining the
#        lock have exited. A command cut off mid-wait is simply run again.
#        For commands needing multiple resources, nest wrappers from outermost
#        to innermost in brief order (declaration order) to avoid deadlock.
# brief  Print the brief section that tells a worker which commands to wrap and
#        how, or nothing when no resource is declared. bin/fm-brief.sh appends it
#        to every ship and scout scaffold.
#
# This file is the single owner of the declaration format, the lock files, and
# the admission rule. docs/configuration.md "Resource locks" is the operator
# reference.
#
# Declaration: config/resource-locks in the local root Firstmate home (the home
# bin/fm-wake-lib.sh's fm_firstmate_root_home resolves), so every home on this
# machine reads the same slots for the same machine's resources. One line per
# resource:
#   <name> <slots> [<HH:MM>-<HH:MM>=<slots>]... <what it covers>
# <name> starts with a letter or digit and holds only letters, digits, `.`, `_`,
# and `-`, and may not contain `-slot-` followed by a digit, which is how slot
# files are named. <slots> is how many jobs may hold the resource at once: a
# positive integer of at most three digits. Each optional window gives a
# different positive count between two local wall-clock times and may cross
# midnight; the first window containing the current time wins.
# The rest of the line says which commands must hold the
# resource and is required, because it is what the brief tells a worker. Blank
# lines and lines starting with `#` are ignored. Any other shape, a resource
# named twice, or an unreadable file makes the whole declaration unreadable:
# brief and run then refuse rather than guess which limit was meant.
#
# Lock files: exclusive flock(1) locks under $XDG_RUNTIME_DIR, which the machine
# clears at logout or reboot. A resource whose most slots at any hour is one
# uses <name>.lock; any other uses <name>-slot-1.lock through
# <name>-slot-<most>.lock. A job that takes the same file with plain flock is
# therefore an ordinary holder, which is how a lock that predates a declaration
# keeps working beside it. Changing a resource between one slot and several
# renames its files, so do that while nothing holds it.
#
# Admission: a job takes the first slot file it can lock, then counts the other
# slot files that are locked. It keeps its slot only while that count is below
# the slots for the current time; otherwise it lets go and polls again. Every
# job that keeps a slot was counted by any job admitted after it, so the limit
# holds without a second lock, and a job that started under a larger count
# keeps its slot when a window lowers it while new jobs wait.
#
# Requires flock(1) and $XDG_RUNTIME_DIR for run; without either, run refuses
# instead of running the command unlocked.
# Test seams: FM_RESOURCE_LOCK_NOW=<HH:MM> replaces the wall clock, and
# FM_RESOURCE_LOCK_POLL_SECS the seconds between polls (default 5).
set -eu

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"
SELF="$SCRIPT_DIR/fm-resource-lock.sh"

usage() {
  awk '
    NR == 1 { next }
    /^#/ { sub(/^# ?/, ""); print; next }
    { exit }
  ' "$0"
}

die() {
  echo "error: $*" >&2
  exit 1
}

# The declaration path: this home's own config directory when the home is the
# local root (so an override of it applies), otherwise the root home's config/.
declaration_path() {
  local home config root home_real
  home="${FM_HOME:-${FM_ROOT_OVERRIDE:-$ROOT}}"
  config="${FM_CONFIG_OVERRIDE:-$home/config}"
  case "$config" in /*) ;; *) config="$PWD/$config" ;; esac
  if [ -e "$home/.fm-secondmate-parent" ] || [ -L "$home/.fm-secondmate-parent" ]; then
    # shellcheck source=bin/fm-wake-lib.sh
    . "$SCRIPT_DIR/fm-wake-lib.sh"
    root=$(fm_firstmate_root_home "$home") ||
      die "could not resolve the root Firstmate home that declares resource locks for $home"
    home_real=$(CDPATH='' cd -- "$home" 2>/dev/null && pwd -P) ||
      die "Firstmate home $home cannot be resolved"
    [ "$root" = "$home_real" ] || config="$root/config"
  fi
  printf '%s/resource-locks\n' "$config"
}

# Minutes since midnight for a validated HH:MM.
minutes_of() {  # <HH:MM>
  local hh=${1%%:*} mm=${1##*:}
  printf '%s\n' "$((10#$hh * 60 + 10#$mm))"
}

valid_time() {  # <HH:MM>
  case "$1" in
    [01][0-9]:[0-5][0-9] | 2[0-3]:[0-5][0-9]) return 0 ;;
  esac
  return 1
}

# A slot count: positive digits, at most three, no leading zero.
valid_count() {  # <count>
  case "$1" in
    '' | *[!0-9]* | ????*) return 1 ;;
    0*) return 1 ;;
  esac
  return 0
}

RL_COUNT=0
RL_NAMES=()
RL_SLOTS=()
RL_WINDOWS=()
RL_WHAT=()

# Read the declaration into the RL_* arrays. An absent file declares nothing.
load_declaration() {  # <file>
  local file=$1 line lineno=0 name slots rest token windows range count start end seen='|'
  RL_COUNT=0
  if [ ! -e "$file" ] && [ ! -L "$file" ]; then
    return 0
  fi
  { [ -f "$file" ] && [ -r "$file" ]; } || die "$file is not a readable regular file"
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%$'\r'}
    line=${line#"${line%%[![:space:]]*}"}
    line=${line%"${line##*[![:space:]]}"}
    case "$line" in
      '' | '#'*) continue ;;
    esac
    name='' slots='' rest=''
    read -r name slots rest <<EOF
$line
EOF
    case "$name" in
      [!A-Za-z0-9]* | *[!A-Za-z0-9._-]* | *-slot-[0-9]*)
        die "$file line $lineno: '$name' is not a resource name (letters, digits, '.', '_', '-', and no '-slot-<digit>')"
        ;;
    esac
    case "$seen" in
      *"|$name|"*) die "$file line $lineno names $name a second time" ;;
    esac
    seen="$seen$name|"
    valid_count "$slots" ||
      die "$file line $lineno gives $name a slot count that is not a positive integer of at most three digits"
    windows=
    while [ -n "$rest" ]; do
      token=${rest%%[[:space:]]*}
      # Anything shaped like a window must be one, so a mistyped window stops
      # the declaration instead of becoming the start of the description.
      case "$token" in
        [0-9]*:*=*) ;;
        *) break ;;
      esac
      range=${token%%=*}
      count=${token#*=}
      start=${range%%-*}
      end=${range##*-}
      { [ "$range" = "$start-$end" ] && valid_time "$start" && valid_time "$end" && [ "$start" != "$end" ]; } ||
        die "$file line $lineno gives $name a window '$range' that is not two different HH:MM times"
      valid_count "$count" ||
        die "$file line $lineno gives $name a window count '$count' that is not a positive integer of at most three digits"
      windows="${windows:+$windows }$token"
      rest=${rest#"$token"}
      rest=${rest#"${rest%%[![:space:]]*}"}
    done
    [ -n "$rest" ] ||
      die "$file line $lineno does not say which commands must hold $name"
    RL_NAMES[RL_COUNT]=$name
    RL_SLOTS[RL_COUNT]=$slots
    RL_WINDOWS[RL_COUNT]=$windows
    RL_WHAT[RL_COUNT]=$rest
    RL_COUNT=$((RL_COUNT + 1))
  done < "$file"
}

# Index of a declared resource, or failure.
resource_index() {  # <name>
  local i=0
  while [ "$i" -lt "$RL_COUNT" ]; do
    if [ "${RL_NAMES[$i]}" = "$1" ]; then
      printf '%s\n' "$i"
      return 0
    fi
    i=$((i + 1))
  done
  return 1
}

# The most slots a resource has at any hour, which fixes its lock files.
most_slots() {  # <index>
  local most=${RL_SLOTS[$1]} token count
  for token in ${RL_WINDOWS[$1]}; do
    count=${token#*=}
    [ "$count" -le "$most" ] || most=$count
  done
  printf '%s\n' "$most"
}

# The slots a resource has at the current local time.
slots_now() {  # <index>
  local now token range start end
  now=${FM_RESOURCE_LOCK_NOW:-$(date +%H:%M)}
  valid_time "$now" || die "FM_RESOURCE_LOCK_NOW must be HH:MM, got '$now'"
  now=$(minutes_of "$now")
  for token in ${RL_WINDOWS[$1]}; do
    range=${token%%=*}
    start=$(minutes_of "${range%%-*}")
    end=$(minutes_of "${range##*-}")
    if [ "$start" -lt "$end" ]; then
      { [ "$now" -ge "$start" ] && [ "$now" -lt "$end" ]; } || continue
    else
      { [ "$now" -ge "$start" ] || [ "$now" -lt "$end" ]; } || continue
    fi
    printf '%s\n' "${token#*=}"
    return 0
  done
  printf '%s\n' "${RL_SLOTS[$1]}"
}

slot_file() {  # <name> <most> <slot>
  if [ "$2" -eq 1 ]; then
    printf '%s/%s.lock\n' "$XDG_RUNTIME_DIR" "$1"
  else
    printf '%s/%s-slot-%s.lock\n' "$XDG_RUNTIME_DIR" "$1" "$3"
  fi
}

# Whether locks can be taken here; prints why not.
lock_support() {
  command -v flock >/dev/null 2>&1 || {
    echo "flock(1) is not installed"
    return 1
  }
  { [ -n "${XDG_RUNTIME_DIR:-}" ] && [ -d "$XDG_RUNTIME_DIR" ] && [ -w "$XDG_RUNTIME_DIR" ]; } || {
    echo "\$XDG_RUNTIME_DIR is not a writable directory"
    return 1
  }
}

cmd_run() {
  local file='' name idx most limit slot held busy path waited=0 poll why lock_fd=9
  if [ "${1:-}" = --file ]; then
    [ $# -ge 2 ] || die "--file needs a declaration path"
    file=$2
    shift 2
  fi
  { [ $# -ge 3 ] && [ "$2" = -- ]; } ||
    die "usage: fm-resource-lock.sh run [--file <declaration>] <resource> -- <command> [arg...]"
  name=$1
  shift 2
  [ -n "$file" ] || file=$(declaration_path)
  load_declaration "$file"
  idx=$(resource_index "$name") ||
    die "resource '$name' is not declared in $file; refusing to run the command unlocked"
  why=$(lock_support) ||
    die "cannot take the $name lock: $why; refusing to run the command unlocked"
  most=$(most_slots "$idx")
  poll=${FM_RESOURCE_LOCK_POLL_SECS:-5}
  while { : >&"$lock_fd"; } 2>/dev/null; do
    lock_fd=$((lock_fd + 1))
  done
  while :; do
    limit=$(slots_now "$idx")
    held=0
    busy=0
    slot=1
    while [ "$slot" -le "$most" ]; do
      path=$(slot_file "$name" "$most" "$slot")
      if [ "$held" -eq 0 ]; then
        eval "exec $lock_fd>> \"\$path\""
        if flock -n "$lock_fd"; then
          held=$slot
        else
          eval "exec $lock_fd>&-"
          busy=$((busy + 1))
        fi
      elif ! flock -n "$path" true; then
        busy=$((busy + 1))
      fi
      slot=$((slot + 1))
    done
    if [ "$held" -gt 0 ]; then
      [ "$busy" -ge "$limit" ] || break
      eval "exec $lock_fd>&-"
    fi
    if [ "$waited" -eq 0 ]; then
      echo "resource-lock: waiting for $name ($limit slot(s) at this hour, none free)" >&2
      waited=1
    fi
    # The jitter keeps two jobs that collided from colliding again.
    sleep "$poll"
    sleep "0.$((RANDOM % 10))"
  done
  echo "resource-lock: holding $name slot $held" >&2
  exec "$@"
}

cmd_brief() {
  local file i=0 self_q file_q counts token
  [ $# -eq 0 ] || die "usage: fm-resource-lock.sh brief"
  file=$(declaration_path)
  load_declaration "$file"
  [ "$RL_COUNT" -gt 0 ] || return 0
  printf -v self_q '%q' "$SELF"
  printf -v file_q '%q' "$file"
  printf '%s\n' \
    '# Heavy commands (resource locks)' \
    'This machine runs only a few of the heavy jobs named below at once, so take a slot yourself instead of asking firstmate.' \
    'Run each such command through its wrapper: it waits for a free slot, runs the command while holding it, and frees the slot when the command and any child processes retaining the lock have exited.' \
    'If a command needs more than one resource, nest wrappers from outermost to innermost in the order the resources are listed below (declaration order), so competing jobs do not deadlock.' \
    "Never run one of these commands outside its wrapper and never preempt another holder; a wait for a slot needs no \`needs-decision\`, and when your shell's command limit ends the wait, run the same wrapped command again."
  while [ "$i" -lt "$RL_COUNT" ]; do
    counts="${RL_SLOTS[$i]} at once"
    for token in ${RL_WINDOWS[$i]}; do
      counts="$counts, ${token#*=} during ${token%%=*}"
    done
    # shellcheck disable=SC2016 # Literal Markdown backticks in the format.
    printf -- '- `%s` (%s) - %s: `%s run --file %s %s -- <command>`\n' \
      "${RL_NAMES[$i]}" "$counts" "${RL_WHAT[$i]}" "$self_q" "$file_q" "${RL_NAMES[$i]}"
    i=$((i + 1))
  done
}

case "${1:-}" in
  -h | --help) usage ;;
  run) shift; cmd_run "$@" ;;
  brief) shift; cmd_brief "$@" ;;
  *)
    usage >&2
    exit 2
    ;;
esac
