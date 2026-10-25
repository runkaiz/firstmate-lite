#!/usr/bin/env bash
# Bootstrap detection, best-effort fleet refresh/prune, and installs.
# Usage: fm-bootstrap.sh
#          Detect: prints one line per actionable problem, or an explicit
#          BOOTSTRAP_INFO no-action fact for completed benign bootstrap work, and
#          exits 0.
#          Silent = all good.
#          Lines: "MISSING: <tool> (install: <command>)",
#                 "PRESENTATION_UNAVAILABLE: lavish-axi (requires >=<floor>; install: <command>) - nonvisual work may proceed with plain-text decisions and reports; install or upgrade before using Lavish",
#                 "MISSING_MANUAL: <tool> (instructions: <url>)", "NEEDS_GH_AUTH",
#                 "BACKEND_INVALID: <name> (known: <names>)",
#                 "STARTUP_MEMORY_BUDGET: invalid config/startup-memory-budget - <reason>",
#                 "CREW_DISPATCH: invalid config/crew-dispatch.json - <reason>",
#                 "FLEET_SYNC: <repo>: skipped|recovered|STUCK: <detail>",
#                 "HOME_SUMMARY: <ledger never published|not republished since
#                 <stamp>>; <n> failed attempt(s) ... last: <recorded failure>",
#                 "BACKLOG_RECONCILE: <id>: <what this home could not reconcile>",
#                 "BACKLOG_RECONCILE: code-root <file> is not this home's <file>; ...",
#                 "TANGLE: <remediation>",
#          A TANGLE line means the firstmate primary checkout (FM_ROOT) is stranded
#          on a feature branch instead of its default branch - a crewmate's work
#          landed in the primary instead of its own worktree; restore it per the line.
#          treehouse is also MISSING when its installed version lacks
#          "treehouse get --lease" support.
#          no-mistakes is also MISSING when its installed version is older than
#          1.46.0 (structured pipeline attestation floor; see CONTRIBUTING.md).
#          The AXI-family floor policy is owned beside GH_AXI_MIN and
#          LAVISH_AXI_MIN below; the per-tool owners point there. An installed
#          essential build below its floor reports MISSING like no-mistakes.
#          Missing or incompatible lavish-axi reports PRESENTATION_UNAVAILABLE;
#          a compatible older build keeps legacy boards and reports a BOOTSTRAP_INFO
#          upgrade recommendation for synchronous reply acceptance.
#          tasks-axi feature probes remain a separate defense-in-depth check.
#          workflow_delivery_tools below owns conditional delivery prerequisites.
#          tasks-axi is required by the automatic backlog backend; quota-axi
#          and jq are required when crew-dispatch.json is configured.
#          Browser tooling is checked when browser work is selected, not here.
#          A compatible tasks-axi default backend is silent.
#          quota-axi is required for the agent-owned dispatch-profile array
#          procedure in AGENTS.md section 4 and
#          .agents/skills/quota-array-dispatch/SKILL.md.
#          On a primary home, the locked mutable path materializes the visible
#          default config/startup-memory-budget=7500 when absent. It never
#          guesses at malformed or unsafe existing files.
#          Fleet sync fetches, fast-forwards safe default-branch states, reports
#          recovered and STUCK clone drift, and prunes gone local branches; it is
#          bounded by FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT when it is a non-empty
#          numeric override, while non-numeric values fall back to 20s.
#          When the override is unset or blank, the timeout is
#          max(20, 5 + 3 * origin-backed project clone count). A timed-out
#          refresh relays any completed fm-fleet-sync.sh output before the
#          aggregate timeout skip line with timeout and elapsed seconds.
#          Set FM_FLEET_PRUNE=0 to skip branch pruning during that refresh.
#          BACKLOG_RECONCILE lines report what backlog_record_reconcile could not
#          settle in THIS home. Every ordinary dispatch and completion now moves
#          the backlog row inside the script that moves the task's record
#          (bin/fm-backlog-transition-lib.sh), so this sweep exists for the
#          crash window inside those scripts and for drift a home was already
#          carrying: it finishes the authoritative close or captain-call
#          retention an interrupted cleanup recorded, and marks In flight any
#          item this home already owns a worker for. The worker-record sweep
#          never starts a captain-held or closed item, and reconciliation never
#          reads or writes another home; the fleet snapshot's classifier and
#          the local snapshot classifier stay as backstops. Replayed
#          transitions and restored In-flight rows print BOOTSTRAP_INFO facts.
#          The `code-root <file>` variant is a detect-only local check that runs
#          even in a read-only session; detect_code_root_backlog_fork owns what
#          it reports.
#          Set FM_BOOTSTRAP_DETECT_ONLY=1 to skip mutating setup, backlog
#          reconciliation, contribution observation and fleet refresh while
#          retaining read-only diagnostics. A TANGLE line is then advisory.
#          FM_BOOTSTRAP_NETWORK partitions local and network work:
#            all (default, including unrecognized values) - both phases.
#            skip - local detection/setup only; no GitHub auth or clone refresh.
#            only - selected GitHub auth and guarded clone refresh only.
#          only plus detect-only performs selected GitHub auth without mutation.
#          bin/fm-startup-network.sh owns deferred execution of the network half;
#          this script owns its commands, guards and diagnostics.
#          Set FM_BOOTSTRAP_LOCKED=1 alongside it when the sweeps are skipped
#          because THIS session already ran them while holding the fleet lock,
#          rather than because it has no lock at all. The two cases differ in
#          exactly one place: repair ownership. A locked session is told to
#          restore a tangled primary checkout itself, while an unlocked one is
#          told to leave that work to the lock holder. Unset/0 (the default)
#          keeps detect-only meaning unlocked, exactly as before.
#        fm-bootstrap.sh install <tool>...
#          Install the named tools (only ones the captain approved).
#        fm-bootstrap.sh lavish-compatible
#          Exit 0 when lavish-axi meets LAVISH_AXI_BOARD_MIN, 1 otherwise,
#          printing nothing; bin/fm-brief.sh uses it to gate scout Lavish hosting.
#        fm-bootstrap.sh lavish-reply-compatible
#          Exit 0 when lavish-axi meets LAVISH_AXI_MIN and supports synchronous
#          reply acceptance, 1 when one version probe confirms an older release
#          meeting LAVISH_AXI_BOARD_MIN, and 2 when lavish-axi is absent, its
#          version cannot be read, or it is below LAVISH_AXI_BOARD_MIN, printing
#          nothing.
set -u

TYPESAFE_API_KEY_PRIVATE=${TYPESAFE_API_KEY:-}
export -n TYPESAFE_API_KEY_PRIVATE 2>/dev/null || true
unset TYPESAFE_API_KEY

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
  echo "error: persistent supervisor homes are no longer supported; private home state is preserved" >&2
  exit 1
fi
PROJECTS="${FM_PROJECTS_OVERRIDE:-$FM_HOME/projects}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-tasks-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tasks-axi-lib.sh"
# shellcheck source=bin/fm-backlog-transition-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-backlog-transition-lib.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-control-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-control-lib.sh"
# shellcheck source=bin/fm-env-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-tangle-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-tangle-lib.sh"
# shellcheck source=bin/fm-ff-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-ff-lib.sh"
# shellcheck source=bin/fm-cursor-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-cursor-lib.sh"
# shellcheck source=bin/fm-startup-memory-budget-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-startup-memory-budget-lib.sh"
# shellcheck source=bin/fm-env-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-env-lib.sh"
# shellcheck source=bin/fm-backend.sh disable=SC1091
. "$SCRIPT_DIR/fm-backend.sh"
# Shared secondmate endpoint probe + guarded relaunch; the watcher's poll tick
# drives the same library so session start and ordinary supervision recover
# from identical evidence through an identical path.
# fm-timing-lib.sh is inert unless FM_TIMING_LOG names a file, which only the
# deferred network stage sets, so an ordinary bootstrap run records nothing.
# shellcheck source=bin/fm-timing-lib.sh disable=SC1091
. "$SCRIPT_DIR/fm-timing-lib.sh"

# Network-phase selection (see the header). An unrecognized value resolves to
# `all` so a malformed override runs every step rather than silently dropping a
# safety sweep.
case "${FM_BOOTSTRAP_NETWORK:-all}" in
  skip|only) FM_BOOTSTRAP_NETWORK_PHASE=${FM_BOOTSTRAP_NETWORK:-all} ;;
  *) FM_BOOTSTRAP_NETWORK_PHASE=all ;;
esac
local_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != only ]; }
network_phase() { [ "$FM_BOOTSTRAP_NETWORK_PHASE" != skip ]; }

network_mutation_authorized() {
  local expected=${FM_BOOTSTRAP_NETWORK_LOCK_PID:-} current
  [ -n "$expected" ] || return 0
  case "$expected" in *[!0-9]*) return 1 ;; esac
  [ -f "$STATE/.lock" ] && [ ! -L "$STATE/.lock" ] || return 1
  current=$(cat "$STATE/.lock" 2>/dev/null) || return 1
  [ "$current" = "$expected" ]
}

network_sweep_authorized() {
  local label=$1
  if network_mutation_authorized; then
    return 0
  fi
  echo "NETWORK_CHECKS: fleet lock ownership changed before $label, so this stale worker skipped that sweep"
  return 1
}





fleet_sync_origin_backed_project_count() {
  local count proj
  count=0
  [ -d "$PROJECTS" ] || { echo 0; return 0; }
  for proj in "$PROJECTS"/*; do
    [ -d "$proj" ] || continue
    git -C "$proj" rev-parse --git-dir >/dev/null 2>&1 || continue
    git -C "$proj" remote get-url origin >/dev/null 2>&1 || continue
    count=$((count + 1))
  done
  echo "$count"
}

fleet_sync_bootstrap_timeout() {
  local count timeout
  if [ -n "${FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT:-}" ]; then
    case "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" in
      *[!0-9]*) echo 20 ;;
      *) echo "$FM_FLEET_SYNC_BOOTSTRAP_TIMEOUT" ;;
    esac
    return 0
  fi

  count=$(fleet_sync_origin_backed_project_count)
  timeout=$((5 + (3 * count)))
  [ "$timeout" -ge 20 ] || timeout=20
  echo "$timeout"
}

fleet_sync_relay_filtered_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    case "$line" in
      *': skipped: local-only project') ;;
      *': skipped: no origin remote') ;;
      *': skipped:'*) echo "FLEET_SYNC: $line" ;;
      *': STUCK:'*) echo "FLEET_SYNC: $line" ;;
      *': recovered:'*) echo "FLEET_SYNC: $line" ;;
    esac
  done < "$tmp"
}

fleet_sync_relay_all_output() {
  local tmp=$1 line
  while IFS= read -r line; do
    [ -n "$line" ] || continue
    echo "FLEET_SYNC: $line"
  done < "$tmp"
}

fleet_sync() {
  [ -x "$FM_ROOT/bin/fm-fleet-sync.sh" ] || return 0
  [ -d "$PROJECTS" ] || return 0

  tmp=$(mktemp "${TMPDIR:-/tmp}/fm-fleet-sync.XXXXXX" 2>/dev/null) || return 0
  timeout=$(fleet_sync_bootstrap_timeout)
  monitor_was_on=0
  case $- in *m*) monitor_was_on=1 ;; esac
  set -m 2>/dev/null || true
  "$FM_ROOT/bin/fm-fleet-sync.sh" >"$tmp" 2>/dev/null &
  pid=$!

  start=$SECONDS
  while jobs -r -p | grep -qx "$pid"; do
    elapsed=$((SECONDS - start))
    if [ "$elapsed" -ge "$timeout" ]; then
      kill -TERM "-$pid" 2>/dev/null || kill "$pid" 2>/dev/null || true
      wait "$pid" 2>/dev/null || true
      [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true
      fleet_sync_relay_all_output "$tmp"
      echo "FLEET_SYNC: fleet: skipped: bootstrap refresh timed out (timeout=${timeout}s elapsed=${elapsed}s)"
      rm -f "$tmp"
      return 0
    fi
    sleep 1
  done
  wait "$pid" 2>/dev/null || true
  [ "$monitor_was_on" -eq 1 ] || set +m 2>/dev/null || true

  fleet_sync_relay_filtered_output "$tmp"
  rm -f "$tmp"
}



install_cmd() {
  case "$1" in
    tmux|node|git|gh|curl|jq|orca|zellij) echo "brew install $1  # or the platform's package manager" ;;
    cmux) echo "brew install --cask cmux  # or see https://cmux.com" ;;
    treehouse) echo "curl -fsSL https://kunchenguid.github.io/treehouse/install.sh | sh" ;;
    no-mistakes) echo "curl -fsSL https://raw.githubusercontent.com/kunchenguid/no-mistakes/main/docs/install.sh | sh" ;;
    gh-axi|chrome-devtools-axi|lavish-axi) echo "npm install -g $1 && $1 setup hooks" ;;
    tasks-axi|quota-axi) echo "npm install -g $1" ;;
    *) return 1 ;;
  esac
}

manual_install_url() {
  case "$1" in
    herdr) echo "https://herdr.dev" ;;
    cursor-agent) echo "https://cursor.com/cli" ;;
    *) return 1 ;;
  esac
}

missing_tool_diagnostic() {
  local tool=$1 instructions
  if instructions=$(manual_install_url "$tool"); then
    echo "MISSING_MANUAL: $tool (instructions: $instructions)"
    return 0
  fi
  echo "MISSING: $tool (install: $(install_cmd "$tool"))"
}

# Required-tool detection follows the RESOLVED backend, not a one-size default:
# a universal toolchain every home needs plus the backend-specific delta owned by
# fm_backend_required_tools (bin/fm-backend.sh). So a herdr/zellij/cmux home is
# never told tmux is missing, and only orca drops treehouse. A backend value with
# no verified dependency set is reported before the universal checks continue.
# The registry and recorded task modes select delivery dependencies.
# Local-only needs neither GitHub nor no-mistakes; direct-PR needs GitHub;
# no-mistakes and conditional/unknown modes need both. Missing registry input
# retains both. Manual backlog needs no tasks-axi. Configured routing needs
# jq and quota-axi. Browser work checks its own feature-specific dependency.
# Missing/unsafe/unknown input stays conservative. No live project is mutated.
workflow_delivery_tools() {
  local names name posture mode kind meta need_github=0 need_validation=0
  if [ ! -f "$DATA/projects.md" ] || [ ! -r "$DATA/projects.md" ] || [ -L "$DATA/projects.md" ]; then
    need_github=1; need_validation=1
  else
    names=$(sed -n '/^- /{ s/^- //; s/ \[.*$//; s/ - .*$//; p; }' "$DATA/projects.md")
    [ -n "$names" ] || { need_github=1; need_validation=1; }
    while IFS= read -r name; do
      [ -n "$name" ] || continue
      posture=$(FM_DATA_OVERRIDE="$DATA" "$SCRIPT_DIR/fm-project-mode.sh" --raw "$name" 2>/dev/null) || posture=unknown
      mode=${posture% *}
      case "$mode" in
        local-only) ;;
        direct-PR) need_github=1 ;;
        *) need_github=1; need_validation=1 ;;
      esac
    done <<< "$names"
  fi
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if [ ! -f "$meta" ] || [ ! -r "$meta" ] || [ -L "$meta" ]; then
      need_github=1; need_validation=1; continue
    fi
    kind=$(fm_meta_get "$meta" kind)
    case "$kind" in scout|secondmate) continue ;; esac
    mode=$(fm_meta_get "$meta" mode)
    case "$mode" in
      local-only) ;;
      direct-PR) need_github=1 ;;
      *) need_github=1; need_validation=1 ;;
    esac
  done
  [ "$need_github" = 0 ] || printf '%s\n' 'gh gh-axi'
  [ "$need_validation" = 0 ] || printf '%s\n' no-mistakes
  return 0
}
COMMON_TOOLS="node git $(workflow_delivery_tools | tr '\n' ' ')"
if ! fm_backlog_backend_manual "$CONFIG"; then COMMON_TOOLS="$COMMON_TOOLS tasks-axi"; fi
if [ -e "$CONFIG/crew-dispatch.json" ] || [ -L "$CONFIG/crew-dispatch.json" ]; then
  COMMON_TOOLS="$COMMON_TOOLS jq quota-axi"
fi
BACKEND=$(fm_backend_name)
BACKEND_VALID=1
if ! BACKEND_TOOLS=$(fm_backend_required_tools "$BACKEND"); then
  BACKEND_VALID=0
  BACKEND_TOOLS=""
fi
TOOLS="$BACKEND_TOOLS $COMMON_TOOLS"
NO_MISTAKES_MIN=1.46.0
# AXI-FAMILY FLOOR POLICY. Every axi-family floor is the CURRENT LATEST published
# version of that tool, captain-bumped periodically to keep the whole fleet on the
# newest axi tools. It is NOT the minimum feature-introduced version. These floors
# are expected to drift upward as new versions ship. Never lower a floor to the
# earliest release that happens to satisfy some depended-on behavior. The
# tasks-axi feature probes are an independent defense-in-depth concern, not part
# of its floor.
GH_AXI_MIN=0.1.29
LAVISH_AXI_MIN=0.1.80
LAVISH_AXI_BOARD_MIN=0.1.77

treehouse_supports_lease() {
  treehouse get --help 2>&1 | grep -Eq '(^|[^[:alnum:]_-])--lease([^[:alnum:]_-]|$)'
}

# Shared semantic-version floor for the tool gates below. A version string that
# cannot be parsed into exactly one major.minor.patch triple is incompatible,
# never assumed current, so a development or vendored build cannot pass a floor
# it was never checked against.
tool_version_parts() {  # <tool>
  local tool=$1 output parts major minor patch extra
  command -v "$tool" >/dev/null 2>&1 || return 1
  output=$("$tool" --version 2>/dev/null) || return 1
  parts=$(printf '%s\n' "$output" | sed -nE 's/.*[vV]?([0-9]+)\.([0-9]+)\.([0-9]+).*/\1 \2 \3/p' | head -n 1)
  IFS=' ' read -r major minor patch extra <<< "$parts"
  [ -n "$major" ] && [ -n "$minor" ] && [ -n "$patch" ] && [ -z "$extra" ] || return 1
  printf '%s %s %s\n' "$major" "$minor" "$patch"
}

version_parts_at_least() {  # <major minor patch> <min-version>
  local major minor patch min=$2 min_major min_minor min_patch min_extra
  IFS=' ' read -r major minor patch <<< "$1"
  IFS='.' read -r min_major min_minor min_patch min_extra <<< "$min"
  [ -n "$min_major" ] && [ -n "$min_minor" ] && [ -n "$min_patch" ] && [ -z "$min_extra" ] || return 1
  [ "$major" -gt "$min_major" ] && return 0
  [ "$major" -eq "$min_major" ] || return 1
  [ "$minor" -gt "$min_minor" ] && return 0
  [ "$minor" -eq "$min_minor" ] || return 1
  [ "$patch" -ge "$min_patch" ]
}

tool_version_at_least() {  # <tool> <min-version>
  local parts
  parts=$(tool_version_parts "$1") || return 1
  version_parts_at_least "$parts" "$2"
}





crew_dispatch_validate() {
  local file err verified_harnesses typed_key typed_active=false
  file="$CONFIG/crew-dispatch.json"
  [ -f "$file" ] || return 0
  if ! command -v jq >/dev/null 2>&1; then
    echo "MISSING: jq (install: $(install_cmd jq))"
    return 0
  fi
  if ! jq -e . "$file" >/dev/null 2>&1; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - malformed JSON"
    return 0
  fi
  typed_key=$TYPESAFE_API_KEY_PRIVATE
  [ -n "$typed_key" ] || typed_key=$(fm_env_get TYPESAFE_API_KEY "$FM_HOME/.env")
  [ -z "$typed_key" ] || typed_active=true
  if $typed_active; then
    verified_harnesses=$(fm_control_harnesses | jq -Rsc 'split("\n") | map(select(length > 0))')
  else
    verified_harnesses='["claude","codex","opencode","pi","pi-signed","grok","kimi","cursor","agy","muse","rovo","omp","devin"]'
  fi
  err=$(jq -r --argjson typed "$typed_active" --argjson verified_harnesses "$verified_harnesses" --arg provider_re "$FM_QUOTA_PROVIDER_ID_RE" '
    def verified($h): $verified_harnesses | index($h);
    def provider_id($p): ($p | type) == "string" and ($p | test($provider_re));
    def effort_ok($h; $m; $e):
      if $e == null then true
      elif ($e | type) != "string" then false
      elif $e == "ultra" then (($h == "pi" or $h == "pi-signed") and (($m | type) == "string") and ($m | startswith("codex-native/")) and ($m | length) > 13)
      elif $h == "claude" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "codex" then ((["low","medium","high","xhigh"] | index($e)) != null or ($e == "max" and $m == "gpt-5.6-luna"))
      elif $h == "grok" then (["low","medium","high"] | index($e))
      elif $h == "agy" then (["low","medium","high"] | index($e))
      elif $h == "pi" or $h == "pi-signed" or $h == "omp" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "muse" then (["low","medium","high","xhigh","max"] | index($e))
      elif $h == "rovo" then (["low","medium","high","max"] | index($e))
      elif $h == "opencode" or $h == "kimi" or $h == "cursor" then false
      else true
      end;
    def profiles($value):
      if ($value | type) == "array" then $value
      elif ($value | type) == "object" then [$value]
      else []
      end;
    def configured_profiles:
      ([(.rules // [])[]? | profiles(.use?)[]?]
        + (if has("default") then [profiles(.default)[]?] else [] end));
    def malformed_optional_fields($items):
      ($items | any(has("model") and (((.model | type) != "string") or (.model | length) == 0)))
      or ($items | any(has("effort") and (((.effort | type) != "string") or (.effort | length) == 0)))
      or ($typed and ($items | any(has("provider") and (provider_id(.provider) | not))));
    # A quota floor, on a rule or a profile: bin/fm-dispatch-resolve.sh applies
    # it in code against one quota-axi row, so scope and min_percent must be
    # concrete; a rule floor also names the provider whose row it reads.
    def floor_bad($f; $need_provider):
      ($f | type) != "object"
      or (($f.scope | type) != "string") or (($f.scope | length) == 0)
      or (($f.min_percent | type) != "number") or ($f.min_percent < 0) or ($f.min_percent > 100)
      or (if $need_provider
          then (provider_id($f.provider) | not)
          else ($f | has("provider"))
          end);
    def malformed_profile_floors($items):
      ($items | any(has("floor") and floor_bad(.floor; false)));
    def bad_efforts:
      configured_profiles
      | map({h: .harness, m: .model, e: .effort})
      | map(select(.e != null))
      | map(select((.h | type) == "string" and verified(.h)))
      | map(select(. as $p | effort_ok($p.h; $p.m; $p.e) | not))
      | map("\(.h):\(.e)")
      | unique;
    if type != "object" then "top-level value must be an object"
    elif has("rules") and (.rules | type) != "array" then "rules must be an array"
    elif [(.rules // [])[]? | select(type != "object")] | length > 0 then "each rule must be an object"
    elif [(.rules // [])[]? | select((.when? | type) != "string" or (.when | length) == 0)] | length > 0 then "each rule needs non-empty when"
    elif [(.rules // [])[]? | select((.use? | type) != "object" and (.use? | type) != "array")] | length > 0 then "each rule needs use"
    elif [(.rules // [])[]? | select((.use? | type) == "array" and (.use | length) == 0)] | length > 0 then "each rule needs at least one use profile"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select(type != "object")] | length > 0 then "each use profile must be an object"
    elif [(.rules // [])[]? | profiles(.use?)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length > 0 then "each use profile needs harness"
    elif malformed_optional_fields([(.rules // [])[]? | profiles(.use?)[]?]) then
      if $typed then "use profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
      else "use profile model and effort must be non-empty strings when present"
      end
    elif $typed and malformed_profile_floors([(.rules // [])[]? | profiles(.use?)[]?]) then "use profile floor needs scope and min_percent 0..100"
    elif $typed and ([(.rules // [])[]? | select(has("approval") and .approval != "captain")] | length > 0) then "approval must be \"captain\" when present"
    elif $typed and ([(.rules // [])[]? | select(has("floor") and floor_bad(.floor; true))] | length > 0) then "rule floor needs scope, min_percent 0..100, and provider matching ^[a-z0-9]+(-[a-z0-9]+)*\\z"
    elif $typed and ([(.rules // [])[]? | select(has("min_confidence") and ((.min_confidence | type) != "number" or .min_confidence < 0 or .min_confidence > 1))] | length > 0) then "min_confidence must be a number from 0 through 1 when present"
    elif [(.rules // [])[]? | select(has("select") and ((.select? | type) != "string" or (.select | length) == 0))] | length > 0 then "select must be a non-empty string"
    elif [(.rules // [])[]? | .select? // empty | select(. != "quota-balanced")] | length > 0 then
      "unknown select: " + ([ (.rules // [])[]? | .select? // empty | select(. != "quota-balanced") ] | unique | join(", "))
    elif has("default") and ((.default | type) != "object" and (.default | type) != "array") then "default must be a profile object or non-empty profile array"
    elif has("default") and ((.default | type) == "array" and (.default | length) == 0) then "default needs at least one profile"
    elif has("default") and ([profiles(.default)[]? | select(type != "object")] | length) > 0 then "each default profile must be an object"
    elif has("default") and ([profiles(.default)[]? | select((.harness? | type) != "string" or (.harness | length) == 0)] | length) > 0 then "each default profile needs harness"
    elif has("default") and malformed_optional_fields([profiles(.default)[]?]) then
      if $typed then "default profile model and effort must be non-empty strings, and provider must match ^[a-z0-9]+(-[a-z0-9]+)*\\z when present"
      else "default profile model and effort must be non-empty strings when present"
      end
    elif $typed and has("default") and malformed_profile_floors([profiles(.default)[]?]) then "default profile floor needs scope and min_percent 0..100"
    else
      (configured_profiles
        | map(.harness)
        | map(select(. != null))
        | map(select(. as $h | verified($h) | not))
        | unique) as $bad_harnesses
      | if ($bad_harnesses | length) > 0 then "unverified harness: " + ($bad_harnesses | join(", "))
        elif (bad_efforts | length) > 0 then "invalid effort: " + (bad_efforts | join(", "))
        else empty
        end
    end
  ' "$file" 2>/dev/null || true)
  if [ -n "$err" ]; then
    echo "CREW_DISPATCH: invalid config/crew-dispatch.json - $err"
    return 0
  fi
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ]; then
    jq -r '
    def profile($p):
      ($p.harness | tostring)
      + (if ($p.model? != null) then "/" + ($p.model | tostring)
         elif ($p.effort? != null) then "/default"
         else "" end)
      + (if ($p.effort? != null) then "/" + ($p.effort | tostring) else "" end);
    def profile_set($value; $selector):
      if ($value | type) == "array" then
        (($selector // "quota-balanced") + "[" + ([$value[] | profile(.)] | join(", ")) + "]")
      else profile($value)
      end;
    (["BOOTSTRAP_INFO: crew dispatch active config/crew-dispatch.json"]
      + [(.rules // [])[]? | "BOOTSTRAP_INFO: crew dispatch rule: " + (.when | tostring) + " -> " + profile_set(.use; .select?)]
      + (if has("default") then ["BOOTSTRAP_INFO: crew dispatch default: " + profile_set(.default; null)] else [] end))
    | .[]
  ' "$file"
  fi
}

# Same-home record reconciliation. Every ordinary dispatch and completion now
# moves the backlog row inside the script that moves the task's record
# (bin/fm-backlog-transition-lib.sh), so remaining recovery cases include a
# process killed mid-transition and drift this home was already carrying. Heal
# this home's OWN books on its own
# restart rather than waiting for a parent's cross-home nudge; the fleet
# snapshot's classifier and the local snapshot classifier stay as
# backstops for what this cannot see. Never reads or writes another home.
backlog_record_reconcile() {
  local marker meta control_lock meta_lock id row label has_record=0 gate_status
  # A fresh home with no state directory has no physical task records to pair.
  # Keep bootstrap diagnostics working without creating state just for a no-op.
  [ -e "$STATE" ] || [ -L "$STATE" ] || return 0
  if ! fm_backlog_directory_present "$STATE" "state directory"; then
    echo "error: backlog reconciliation refused: $FM_BACKLOG_TRANSITION_ERROR" >&2
    return 2
  fi
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
    :
  else
    gate_status=$?
    if [ "$gate_status" -eq 2 ]; then
      echo "error: backlog reconciliation cannot access configured data directory $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      return 2
    fi
    return 0
  fi
  # Keep the wake/lock library's source-time state-directory creation inside
  # this mutating sweep, so FM_BOOTSTRAP_DETECT_ONLY remains read-only.
  # shellcheck source=bin/fm-wake-lib.sh disable=SC1091
  . "$SCRIPT_DIR/fm-wake-lib.sh"

  # Finish any close an interrupted cleanup recorded but never landed.
  for marker in "$STATE"/*.backlog-close; do
    [ -e "$marker" ] || [ -L "$marker" ] || continue
    if ! fm_backlog_record_present "$marker" "pending-close record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe pending close refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    label=$(basename "$marker" .backlog-close)
    control_lock="$STATE/.control-$label.lock"
    meta_lock=$(fm_meta_lock_path "$STATE/$label.meta") || continue
    fm_lock_try_acquire "$control_lock" || continue
    if ! fm_lock_try_acquire "$meta_lock"; then
      fm_lock_release "$control_lock"
      continue
    fi
    if fm_backlog_close_marker_replay "$STATE" "$marker" "$DATA"; then
      case "$FM_BACKLOG_CLOSE_REPLAY_RESULT" in
        closed)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label that an interrupted cleanup left open"
          ;;
        closed_incomplete)
          echo "BOOTSTRAP_INFO: closed the backlog item for $label after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        retained)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after an interrupted cleanup"
          ;;
        retained_incomplete)
          echo "BOOTSTRAP_INFO: kept the captain call for $label open with its deliverable recorded after interrupted cleanup; its endpoint or local copy may remain and should be reconciled"
          ;;
        answered)
          echo "BOOTSTRAP_INFO: finished the interrupted cleanup for $label; the captain had already answered its call"
          ;;
      esac
    else
      echo "BACKLOG_RECONCILE: $label: recorded backlog close could not be replayed: $FM_BACKLOG_TRANSITION_ERROR"
    fi
    fm_lock_release "$meta_lock"
    fm_lock_release "$control_lock"
  done

  # A home that owns no records has nothing to pair, so it never pays for a
  # backlog read. A pending close remains authoritative even when replay failed:
  # the record sweep below must not start that item while its marker survives.
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    has_record=1
    break
  done
  [ "$has_record" = 1 ] || return 0
  for meta in "$STATE"/*.meta; do
    [ -e "$meta" ] || [ -L "$meta" ] || continue
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: unsafe worker record refused: $FM_BACKLOG_TRANSITION_ERROR"
      return 2
    fi
    id=$(basename "$meta" .meta)
    meta_lock=$(fm_meta_lock_path "$meta") || continue
    fm_lock_try_acquire "$meta_lock" || continue
    if [ -e "$STATE/$id.backlog-close" ] || [ -L "$STATE/$id.backlog-close" ]; then
      fm_lock_release "$meta_lock"
      continue
    fi
    if ! fm_backlog_record_present "$meta" "task record" "$STATE"; then
      echo "BACKLOG_RECONCILE: $id: post-lock worker record check refused: $FM_BACKLOG_TRANSITION_ERROR"
      fm_lock_release "$meta_lock"
      return 2
    fi
    if [ "$(fm_meta_get "$meta" kind)" != secondmate ] \
       && [ "$(fm_meta_get "$meta" cleanup_recovery)" != orca ]; then
      row=
      if fm_backlog_row_probe "$DATA" "$id"; then
        row=$FM_BACKLOG_ROW_STATE
      elif [ "$FM_BACKLOG_ROW_RESULT" != not_found ]; then
        echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be read: $FM_BACKLOG_ROW_ERROR"
      fi
      # Heal only the unambiguous case: a queued row for a record this home
      # already owns. A held row is the captain's to move, and a closed row is a
      # contradiction this sweep must not resolve by resurrecting the item.
      if [ "$row" = "queued no no" ]; then
        if fm_backlog_start "$DATA" "$id"; then
          echo "BOOTSTRAP_INFO: marked $id in flight to match the worker this home already owns"
        else
          echo "BACKLOG_RECONCILE: $id: worker record exists but its backlog item could not be moved to In flight: $FM_BACKLOG_TRANSITION_ERROR"
        fi
      fi
    fi
    fm_lock_release "$meta_lock"
  done
}

startup_memory_budget_setup() {
  # Primary bootstrap owns default publication. A secondmate is deliberately
  # passive here because its setting must converge from the primary through the
  # inherited-local-material contract rather than becoming a local authority.
  if [ -e "$FM_HOME/.fm-secondmate-home" ] || [ -L "$FM_HOME/.fm-secondmate-home" ]; then
    return 0
  fi
  if ! fm_startup_memory_budget_materialize "$CONFIG"; then
    echo "STARTUP_MEMORY_BUDGET: invalid config/$FM_STARTUP_MEMORY_BUDGET_FILE - $FM_STARTUP_MEMORY_BUDGET_ERROR"
  fi
}

if [ "${1:-}" = "lavish-compatible" ]; then
  tool_version_at_least lavish-axi "$LAVISH_AXI_BOARD_MIN"
  exit
fi

if [ "${1:-}" = "lavish-reply-compatible" ]; then
  lavish_parts=$(tool_version_parts lavish-axi) || exit 2
  version_parts_at_least "$lavish_parts" "$LAVISH_AXI_MIN" && exit 0
  version_parts_at_least "$lavish_parts" "$LAVISH_AXI_BOARD_MIN" && exit 1
  exit 2
fi

if [ "${1:-}" = "install" ]; then
  shift
  [ $# -gt 0 ] || { echo "usage: fm-bootstrap.sh install <tool>..." >&2; exit 1; }
  for t in "$@"; do
    if ! cmd=$(install_cmd "$t"); then
      instructions=$(manual_install_url "$t") || { echo "error: unknown tool $t" >&2; exit 1; }
      echo "error: $t requires manual installation (instructions: $instructions)" >&2
      exit 1
    fi
    cmd=${cmd%%  #*}
    echo "installing $t: $cmd"
    eval "$cmd"
  done
  exit 0
fi

# This is the first mutating sweep at a locked session boundary. Detect-only
# sessions never touch state, and the deferred network pass never repeats it:
# the local pass that ran first already closed that window.
if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ] && local_phase; then
  BOOTSTRAP_BACKLOG_GATE_KIND=none
  if [ -e "$STATE" ] || [ -L "$STATE" ]; then
    if ! fm_backlog_directory_present "$STATE" "state directory"; then
      echo "error: bootstrap cannot reconcile task state ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
    for BOOTSTRAP_BACKLOG_MARKER in "$STATE"/*.backlog-close; do
      [ -e "$BOOTSTRAP_BACKLOG_MARKER" ] || [ -L "$BOOTSTRAP_BACKLOG_MARKER" ] || continue
      if ! fm_backlog_record_present "$BOOTSTRAP_BACKLOG_MARKER" "pending-close record" "$STATE"; then
        echo "error: bootstrap refused unsafe pending close ($FM_BACKLOG_TRANSITION_ERROR)" >&2
        exit 1
      fi
      BOOTSTRAP_BACKLOG_GATE_KIND=ship
      break
    done
    if [ "$BOOTSTRAP_BACKLOG_GATE_KIND" = none ]; then
      for BOOTSTRAP_BACKLOG_META in "$STATE"/*.meta; do
        [ -e "$BOOTSTRAP_BACKLOG_META" ] || [ -L "$BOOTSTRAP_BACKLOG_META" ] || continue
        if ! fm_backlog_record_present "$BOOTSTRAP_BACKLOG_META" "task record" "$STATE"; then
          echo "error: bootstrap refused unsafe worker record ($FM_BACKLOG_TRANSITION_ERROR)" >&2
          exit 1
        fi
        if [ "$(fm_meta_get "$BOOTSTRAP_BACKLOG_META" kind)" != secondmate ] \
           && [ "$(fm_meta_get "$BOOTSTRAP_BACKLOG_META" cleanup_recovery)" != orca ]; then
          BOOTSTRAP_BACKLOG_GATE_KIND=ship
          break
        fi
      done
    fi
  fi
  if fm_backlog_transition_applies "$CONFIG" "$DATA" "$BOOTSTRAP_BACKLOG_GATE_KIND"; then
    :
  else
    BOOTSTRAP_BACKLOG_GATE_STATUS=$?
    if [ "$BOOTSTRAP_BACKLOG_GATE_STATUS" -eq 2 ]; then
      echo "error: bootstrap cannot access configured backlog data directory $DATA ($FM_BACKLOG_TRANSITION_ERROR)" >&2
      exit 1
    fi
  fi
  startup_memory_budget_setup
  if backlog_record_reconcile; then
    :
  else
    BOOTSTRAP_BACKLOG_RECONCILE_STATUS=$?
    if [ "$BOOTSTRAP_BACKLOG_RECONCILE_STATUS" -eq 2 ]; then
      exit 1
    fi
  fi
fi

# Local detection: presence, version floors, and configuration. Nothing here
# leaves this machine, so it stays on the session-start critical path.
detect_local_tools() {
  if [ "$BACKEND_VALID" -eq 0 ]; then
    echo "BACKEND_INVALID: $BACKEND (known: $FM_BACKEND_KNOWN)"
  fi
  for t in $BACKEND_TOOLS; do
    fm_backend_required_tool_available "$BACKEND" "$t" \
      || missing_tool_diagnostic "$t"
  done
  for t in $COMMON_TOOLS; do
    command -v "$t" >/dev/null || missing_tool_diagnostic "$t"
  done
  # The treehouse lease-support upgrade check is only relevant when the resolved
  # backend actually requires treehouse (every backend except orca, which owns its
  # own worktrees); an orca home must not be told to upgrade a provider it never uses.
  if fm_backend_list_contains "$TOOLS" treehouse \
    && command -v treehouse >/dev/null 2>&1 && ! treehouse_supports_lease; then
    echo "MISSING: treehouse (install: $(install_cmd treehouse))"
  fi
  if fm_backend_list_contains "$COMMON_TOOLS" no-mistakes && command -v no-mistakes >/dev/null 2>&1 && ! tool_version_at_least no-mistakes "$NO_MISTAKES_MIN"; then
    echo "MISSING: no-mistakes (install: $(install_cmd no-mistakes))"
  fi
  if fm_backend_list_contains "$COMMON_TOOLS" gh-axi && command -v gh-axi >/dev/null 2>&1 && ! tool_version_at_least gh-axi "$GH_AXI_MIN"; then
    echo "MISSING: gh-axi (install: $(install_cmd gh-axi))"
  fi
  if ! tool_version_at_least lavish-axi "$LAVISH_AXI_BOARD_MIN"; then
    echo "PRESENTATION_UNAVAILABLE: lavish-axi (requires >=$LAVISH_AXI_BOARD_MIN; install: $(install_cmd lavish-axi)) - nonvisual work may proceed with plain-text decisions and reports; install or upgrade before using Lavish"
  elif ! tool_version_at_least lavish-axi "$LAVISH_AXI_MIN"; then
    echo "BOOTSTRAP_INFO: lavish-axi >=$LAVISH_AXI_MIN enables confirmed board replies; this older compatible version retains the legacy reply path, but upgrade to prevent handing back a board before its reply is accepted"
  fi
  if fm_backend_list_contains "$COMMON_TOOLS" quota-axi && command -v quota-axi >/dev/null 2>&1 && ! fm_quota_axi_compatible; then
    echo "MISSING: quota-axi (install: $(install_cmd quota-axi))"
  fi
  if fm_backend_list_contains "$COMMON_TOOLS" tasks-axi && command -v tasks-axi >/dev/null 2>&1 && ! fm_tasks_axi_compatible; then
    echo "MISSING: tasks-axi (install: $(install_cmd tasks-axi))"
  fi
}

detect_local_config() {
  # Worktree-tangle check: the firstmate primary checkout (FM_ROOT) must sit on its
  # default branch, not a feature branch (see fm-tangle-lib.sh). Scoped to the
  # primary only; detached-HEAD worktrees and secondmate homes never trip it.
  tangle_branch=$(fm_primary_tangle_branch "$FM_ROOT" 2>/dev/null || true)
  if [ -n "$tangle_branch" ]; then
    tangle_default=$(fm_default_branch "$FM_ROOT" 2>/dev/null || echo main)
    if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" = 1 ] && [ "${FM_BOOTSTRAP_LOCKED:-0}" != 1 ]; then
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - read-only session must leave restore work to the session holding the fleet lock"
    else
      echo "TANGLE: primary checkout on feature branch '$tangle_branch' (expected '$tangle_default'); the work is safe on that ref - restore the primary with: git -C $FM_ROOT checkout $tangle_default, then re-validate the branch in a proper worktree"
    fi
  fi
  crew=
  [ -f "$CONFIG/crew-harness" ] && crew=$(tr -d '[:space:]' < "$CONFIG/crew-harness" || true)
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] && [ -n "$crew" ] && [ "$crew" != "default" ]; then
    echo "BOOTSTRAP_INFO: crew harness override active: $crew"
  fi
  # A configured cursor crew harness needs a cursor executable present, and
  # cursor ships under EITHER installed name. Resolution runs through the
  # verified owner rather than a bare `command -v`, so a home that merely has
  # some unrelated executable named `agent` on PATH is still reported missing
  # instead of failing at the first spawn.
  if [ "$crew" = cursor ] && ! fm_cursor_resolve_binary >/dev/null 2>&1; then
    echo "MISSING_MANUAL: cursor-agent (instructions: $(manual_install_url cursor-agent))"
  fi
  crew_dispatch_validate
  if [ "${FM_BOOTSTRAP_VERBOSE_FACTS:-0}" = 1 ] \
    && ! fm_backlog_backend_manual "$CONFIG" && fm_tasks_axi_compatible; then
    echo "BOOTSTRAP_INFO: tasks-axi available"
  fi
  detect_code_root_backlog_fork
  detect_home_summary_publication
}

# Shadow-backlog check. When this home's data directory is not the code root's,
# a code-root data/backlog.md or data/done-archive.md that is not this home's
# own file is a queue a cwd-relative tasks-axi write has already forked; a link
# into the home does not survive such a write (docs/configuration.md "Backlog
# backend" owns why). Detect-only: neither copy is a safe winner, so nothing is
# merged here.
detect_code_root_backlog_fork() {
  local name root_copy
  [ "$FM_ROOT/data" -ef "$DATA" ] && return 0
  for name in backlog.md done-archive.md; do
    root_copy="$FM_ROOT/data/$name"
    [ -e "$root_copy" ] || [ -L "$root_copy" ] || continue
    [ "$root_copy" -ef "$DATA/$name" ] && continue
    echo "BACKLOG_RECONCILE: code-root $root_copy is not this home's $DATA/$name; tasks-axi wrote the code root instead of this home, so rows in it may be missing here - merge it into this home's copy and move it aside"
  done
}

# This home's ledger publication is deliberately best-effort: every lifecycle
# trigger calls it with --best-effort so a failure can never change the result
# of a session start, a spawn, a teardown, or a watcher poll. That is correct,
# and it also means a home that never manages to publish says nothing at all -
# the failures land only in the bounded home-local record nobody reads.
#
# So read that same record here, where a session start already looks, and say so
# once when the evidence is a pattern rather than a blip: the ledger has not
# been (re)published, and at least FM_HOME_SUMMARY_FAILURE_REPORT attempts have
# failed since whenever it last was. No new record, no new state, no retry
# policy - just the existing evidence, surfaced.
detect_home_summary_publication() {
  local log="$STATE/.home-summary-refresh.log" ledger="$STATE/home-summary.json"
  local since='' counted failures last threshold
  threshold=${FM_HOME_SUMMARY_FAILURE_REPORT:-2}
  case "$threshold" in ''|*[!0-9]*|0) threshold=2 ;; esac
  [ -f "$log" ] && [ -r "$log" ] && [ ! -L "$log" ] || return 0
  if [ -f "$ledger" ] && [ -r "$ledger" ] && [ ! -L "$ledger" ]; then
    since=$(LC_ALL=C sed -n 's/.*"generated"[[:space:]]*:[[:space:]]*"\([^"]*\)".*/\1/p' \
      "$ledger" 2>/dev/null | head -1)
  fi
  # Publication and failure stamps have whole-second precision, so failures in
  # the publication's own second remain quiet until a later failure advances
  # the record. That bounded delay avoids a precision dependency in bootstrap.
  counted=$(LC_ALL=C awk -v since="$since" '
    match($0, /^\[[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]T[0-9][0-9]:[0-9][0-9]:[0-9][0-9]Z\]/) {
      stamp = substr($0, 2, RLENGTH - 2)
      if (since == "" || stamp > since) {
        n += 1
        last = substr($0, RLENGTH + 2)
      } else if (stamp == since) {
        same_second += 1
      }
    }
    END {
      if (since != "" && n > 0) n += same_second
      printf "%d\t%s", n + 0, last
    }' "$log" 2>/dev/null) || return 0
  failures=${counted%%$'\t'*}
  last=${counted#*$'\t'}
  case "$failures" in ''|*[!0-9]*) return 0 ;; esac
  [ "$failures" -ge "$threshold" ] || return 0
  last=$(printf '%s' "$last" | cut -c1-200)
  if [ -z "$since" ]; then
    echo "HOME_SUMMARY: this home has never published state/home-summary.json; $failures failed attempt(s) recorded in state/.home-summary-refresh.log, last: $last"
  else
    echo "HOME_SUMMARY: state/home-summary.json has not been republished since $since; $failures failed attempt(s) recorded in state/.home-summary-refresh.log, last: $last"
  fi
}

# The order below is the order the diagnostics have always printed in, so a
# `skip` run is the same output with the network lines removed rather than a
# reshuffle. `gh auth status` sits between the two local blocks because that is
# where it has always been.
# Each network owner below is bracketed by an elapsed-time record, so a deferred
# stage that ran long can be attributed to the phase that spent the time.
# fm-timing-lib.sh discards the record unless the caller asked for timings, and
# every sweep is still called directly. Per-secondmate remote probes run
# concurrently; clone refresh overlaps them. Diagnostic lines are replayed in
# original order so attribution is unchanged.
# The stamp variable is named for the library rather than `start` on purpose:
# fleet_sync and others assign plain names like `start` without `local`, and
# bash's dynamic scoping would let them overwrite a stamp held by a caller.
local_phase && detect_local_tools
if network_phase && fm_backend_list_contains "$COMMON_TOOLS" gh; then
  __fm_timing_stamp=$(fm_timing_now_ms)
  gh auth status >/dev/null 2>&1 || echo "NEEDS_GH_AUTH"
  fm_timing_record phase gh-auth "$__fm_timing_stamp"
fi
local_phase && detect_local_config

if [ "${FM_BOOTSTRAP_DETECT_ONLY:-0}" != 1 ]; then
  # secondmate_sync consumes SECONDMATE_RESPAWNED_IDS from the liveness sweep, so
  # those two always run together in the same phase. Clone refresh does not
  # depend on them, so it starts in the background and overlaps their wall clock.
  fleet_sync_pid=
  fleet_sync_out=
  if network_phase && network_sweep_authorized 'project clone refresh'; then
    fleet_sync_out=$(mktemp "${TMPDIR:-/tmp}/fm-bootstrap-fleet.XXXXXX") || fleet_sync_out=
    if [ -n "$fleet_sync_out" ]; then
      (
        __fm_timing_stamp=$(fm_timing_now_ms)
        fleet_sync
        fm_timing_record phase fleet-sync "$__fm_timing_stamp"
      ) >"$fleet_sync_out" 2>&1 &
      fleet_sync_pid=$!
    else
      __fm_timing_stamp=$(fm_timing_now_ms)
      fleet_sync
      fm_timing_record phase fleet-sync "$__fm_timing_stamp"
    fi
  fi

  if local_phase && command -v jq >/dev/null 2>&1 \
    && [ -d "$DATA" ] && [ -x "$SCRIPT_DIR/fm-contributions.sh" ]; then
    "$SCRIPT_DIR/fm-contributions.sh" arm --if-owned >/dev/null \
      || echo "MISSING: contribution observation could not be armed; coverage is unconfirmed"
  fi
  if [ -n "$fleet_sync_pid" ]; then
    wait "$fleet_sync_pid" || true
    cat "$fleet_sync_out"
    rm -f "$fleet_sync_out"
  fi
fi
exit 0
