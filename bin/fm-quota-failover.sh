#!/usr/bin/env bash
# fm-quota-failover.sh - move worker launches off a runtime whose quota is
# positively known to be exhausted, onto the next configured dispatch candidate.
#
# Usage:
#   fm-quota-failover.sh pick --harness <name> [--model <name>] [--effort <level>]
#   fm-quota-failover.sh record --harness <name> [--model <name>]
#                               [--until <epoch>] [--why <text>]
#   fm-quota-failover.sh relaunch <task-id>
#
# pick      Print the profile a fresh spawn should launch, as one line
#           "<harness>|<model>|<effort>" (empty fields mean the harness
#           default). The requested profile comes back unchanged unless its
#           quota is positively known exhausted; then the next configured
#           candidate that is not known exhausted comes back instead, with one
#           `quota:` line on stderr naming both and the evidence. When every
#           configured candidate is known exhausted it prints one `deferred:`
#           line on stderr and exits 75, so the work stays queued.
#           bin/fm-spawn.sh runs this for every fresh ship or scout spawn with
#           an explicit adapter while config/crew-dispatch.json exists.
# record    Remember that a profile's provider hit a genuine quota or usage
#           limit, until <epoch> (default: now + 5 hours). Firstmate may call it
#           when it sees such a failure that this script did not detect itself.
# relaunch  For a ship or scout whose terminal shows a genuine quota or usage
#           limit failure, record it, choose the next configured candidate as
#           pick does, and replace the worker ONCE through
#           bin/fm-control.sh <task-id> relaunch with a progress note, in the
#           same local copy. Exits 3 without changing anything when no quota
#           failure is visible, 75 when no configured candidate has quota left,
#           and refuses a second switch for the same task, so it never loops.
#
# "Positively known exhausted" means either an unexpired record in
# state/quota-failures, or one bounded `quota-axi --json` read whose applicable
# runway for the candidate's provider is exhausted_now or a known zero
# (quota_effective in bin/fm-quota-axi-lib.sh). A missing, failing, or silent
# quota-axi is uncertainty, never exhaustion, so it never moves a launch.
#
# A candidate's provider is its profile's declared `provider`, else the primary
# family from fm_quota_provider_for_harness, else `harness:<name>`. Candidates,
# in order: every rule `use` set containing the requested profile (same
# harness, and the same model when both name one), then `default`, without
# duplicates and without the requested profile itself.
#
# A quota failure is genuine only when one of the last 12 non-blank terminal
# lines carries a usage-limit or quota-exhaustion message: "usage limit
# exceeded/reached" (Pi's GoUsageLimitError), "reached their ... usage limit"
# (ChatGPT subscription sharing), "hit your (usage) limit" (Codex, Claude),
# "<window> limit reached", insufficient_quota, or "quota exceeded/exhausted".
# A bare 429, "rate limit", or overload message is transient and never counts.
#
# The switch changes only the worker runtime. Task identity, local copy, brief,
# pipeline run, and account pins stay as they are: bin/fm-control.sh still
# applies config/claude-account and config/pi-account before stopping anything,
# and no-mistakes validation-agent settings are never read or written here.
#
# Environment: FM_HOME (required), FM_STATE_OVERRIDE, FM_CONFIG_OVERRIDE.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

die() { printf 'error: %s\n' "$1" >&2; exit "${2:-1}"; }
usage() { sed -n '2,${/^#/!q;p;}' "$0" | sed 's/^# \{0,1\}//'; }

case "${1:-}" in -h|--help|help) usage; exit 0 ;; esac
[ -n "${FM_HOME:-}" ] || die "FM_HOME is not set; fm-quota-failover refuses to guess which home's quota records to use" 2

# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-quota-axi-lib.sh
. "$SCRIPT_DIR/fm-quota-axi-lib.sh"
# shellcheck source=bin/fm-timeout-lib.sh
. "$SCRIPT_DIR/fm-timeout-lib.sh"

FAILURE_TTL=18000
QUOTA_AXI_TIMEOUT=15
QUOTA_FAILURE_RE='usage ?limit ?(error|exceeded|reached)|reached (their|your) [a-z ]*usage limit|hit your (usage )?limit|(weekly|session|5-hour|daily|monthly) (usage )?limit (reached|exceeded|hit)|insufficient_quota|exceeded your current quota|quota (exceeded|exhausted)'

STATE="${FM_STATE_OVERRIDE:-$FM_HOME/state}"
CONFIG="${FM_CONFIG_OVERRIDE:-$FM_HOME/config}"
FAILURES="$STATE/quota-failures"
DISPATCH="$CONFIG/crew-dispatch.json"
NOW=$(date +%s)
QUOTA_JSON=
QUOTA_READ=0

profile_provider() {  # <harness> <model> <declared-provider>
  [ -z "$3" ] || { printf '%s\n' "$3"; return; }
  fm_quota_provider_for_harness "$1" "$2" 2>/dev/null || printf 'harness:%s\n' "$1"
}

# The requested profile's declared provider, when the dispatch file names one.
declared_provider() {  # <harness> <model>
  [ -f "$DISPATCH" ] || return 0
  jq -r --arg h "$1" --arg m "$2" '
    [(.rules // [])[].use, .default | select(. != null) | if type == "array" then .[] else . end
     | select(.harness == $h and ((.model // "") == $m or $m == "" or (.model // "") == ""))
     | .provider // empty] | first // empty' "$DISPATCH" 2>/dev/null || true
}

quota_snapshot() {
  [ "$QUOTA_READ" = 1 ] && return 0
  QUOTA_READ=1
  command -v quota-axi >/dev/null 2>&1 || return 0
  QUOTA_JSON=$(fm_run_timed "$QUOTA_AXI_TIMEOUT" quota-axi --json 2>/dev/null </dev/null) || QUOTA_JSON=
  printf '%s\n' "$QUOTA_JSON" | fm_quota_json_valid || QUOTA_JSON=
}

# Prints the evidence and succeeds only when the profile is known exhausted.
exhausted_evidence() {  # <harness> <model> <provider>
  local key until why scope_model effective
  if [ -f "$FAILURES" ]; then
    while IFS=$'\t' read -r key until why; do
      [ "$key" = "$3" ] || continue
      case "$until" in ''|*[!0-9]*) continue ;; esac
      [ "$until" -gt "$NOW" ] || continue
      printf 'recorded quota failure for %s until %s (%s)\n' "$3" "$(date -u -d "@$until" +%Y-%m-%dT%H:%MZ 2>/dev/null || date -u -r "$until" +%Y-%m-%dT%H:%MZ 2>/dev/null || printf '%s' "$until")" "${why:-no detail}"
      return 0
    done < "$FAILURES"
  fi
  case "$3" in harness:*) return 1 ;; esac
  quota_snapshot
  [ -n "$QUOTA_JSON" ] || return 1
  scope_model=${2##*/}
  effective=$(printf '%s\n' "$QUOTA_JSON" | jq -r --arg h "$1" --arg m "$2" --arg sm "$scope_model" --arg p "$3" \
    "$FM_QUOTA_ROW_JQ"'quota_effective(.; $p; $sm; quota_lane($h; $m)) |
      if (.runway.status // "") == "exhausted_now" or (.status == "known" and .effectivePercentRemaining == 0)
      then "quota-axi reports \($p) \(.scope // "quota") exhausted" else empty end' 2>/dev/null) || effective=
  [ -n "$effective" ] || return 1
  printf '%s\n' "$effective"
}

# Ordered "<harness>|<model>|<effort>|<provider>" lines, excluding the request.
candidates() {  # <harness> <model> <effort>
  [ -f "$DISPATCH" ] || return 0
  jq -r --arg h "$1" --arg m "$2" --arg e "$3" '
    def profiles: if . == null then [] elif type == "array" then . else [.] end;
    def matches: .harness == $h and ((.model // "") == $m or $m == "" or (.model // "") == "");
    ([(.rules // [])[] | .use | profiles | select(any(.[]; matches)) | .[]] + (.default | profiles))
    | map({harness, model: (.model // ""), effort: (.effort // ""), provider: (.provider // "")})
    | reduce .[] as $c ([]; if any(.[]; .harness == $c.harness and .model == $c.model and .effort == $c.effort) then . else . + [$c] end)
    | map(select((.harness == $h and .model == $m and .effort == $e) | not))
    | .[] | [.harness, .model, .effort, .provider] | join("|")' "$DISPATCH" 2>/dev/null \
    || die "config/crew-dispatch.json cannot be read as dispatch profiles; fix it rather than switching around it" 2
}

# Sets CHOSEN to the profile to launch; returns 75 when nothing has quota.
choose() {  # <harness> <model> <effort>
  local provider evidence h m e p list
  provider=$(profile_provider "$1" "$2" "$(declared_provider "$1" "$2")")
  CHOSEN="$1|$2|$3"
  evidence=$(exhausted_evidence "$1" "$2" "$provider") || return 0
  list=$(candidates "$1" "$2" "$3") || exit $?
  while IFS='|' read -r h m e p; do
    [ -n "$h" ] || continue
    p=$(profile_provider "$h" "$m" "$p")
    exhausted_evidence "$h" "$m" "$p" >/dev/null && continue
    CHOSEN="$h|$m|$e"
    printf 'quota: %s %s is exhausted (%s); using %s %s instead\n' "$1" "${2:-default}" "$evidence" "$h" "${m:-default}" >&2
    return 0
  done <<< "$list"
  printf 'deferred: %s %s is exhausted (%s) and no other configured dispatch profile has quota left, so the work stays queued\n' "$1" "${2:-default}" "$evidence" >&2
  return 75
}

record_failure() {  # <harness> <model> <until> <why>
  local provider why=${4//$'\t'/ }
  provider=$(profile_provider "$1" "$2" "$(declared_provider "$1" "$2")")
  mkdir -p "$STATE"
  printf '%s\t%s\t%s\n' "$provider" "$3" "${why//$'\n'/ }" >> "$FAILURES" \
    || die "cannot record the quota failure in $FAILURES"
}

parse_profile_flags() {
  HARNESS='' MODEL='' EFFORT='' UNTIL=$((NOW + FAILURE_TTL)) WHY=''
  while [ "$#" -gt 0 ]; do
    case "$1" in
      --harness|--model|--effort|--until|--why)
        [ "$#" -ge 2 ] || die "$1 needs a value" 2
        case "$1" in
          --harness) HARNESS=$2 ;; --model) MODEL=$2 ;; --effort) EFFORT=$2 ;;
          --until) UNTIL=$2 ;; --why) WHY=$2 ;;
        esac
        shift 2 ;;
      *) die "unknown argument: $1" 2 ;;
    esac
  done
  [ -n "$HARNESS" ] || die "--harness is required" 2
  [ "$MODEL" != default ] || MODEL=
  [ "$EFFORT" != default ] || EFFORT=
  case "$UNTIL" in ''|*[!0-9]*) die "--until must be a Unix epoch" 2 ;; esac
}

relaunch_task() {  # <task-id>
  local id=$1 meta marker kind harness model effort pane line h m e note rc
  case "$id" in ''|*/*|.*) die "relaunch needs an exact task id" 2 ;; esac
  meta="$STATE/$id.meta"
  [ -f "$meta" ] || die "no task record for '$id' in this home"
  kind=$(fm_meta_get "$meta" kind)
  case "${kind:-ship}" in ship|scout) ;; *) die "task '$id' is a $kind, not a ship or scout worker" ;; esac
  marker="$STATE/$id.quota-failover"
  [ ! -e "$marker" ] || die "task '$id' already switched runtime once after a quota failure ($(head -n 1 "$marker" 2>/dev/null)); not retrying, so firstmate decides the next step"
  harness=$(fm_meta_get "$meta" harness)
  model=$(fm_meta_get "$meta" model)
  effort=$(fm_meta_get "$meta" effort)
  [ -n "$harness" ] || die "task '$id' records no harness"
  pane=$(FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-peek.sh" "$id" 60 2>/dev/null) \
    || die "cannot read task '$id''s terminal to confirm a quota failure"
  line=$(printf '%s\n' "$pane" | grep -v '^[[:space:]]*$' | tail -n 12 | grep -Ei -- "$QUOTA_FAILURE_RE" | tail -n 1 | sed 's/^[[:space:]]*//' | cut -c1-200)
  if [ -z "$line" ]; then
    echo "no quota failure is visible in task '$id''s terminal; nothing changed"
    exit 3
  fi
  record_failure "$harness" "$model" "$((NOW + FAILURE_TTL))" "task $id: $line"
  choose "$harness" "$model" "$effort" || exit $?
  IFS='|' read -r h m e <<< "$CHOSEN"
  [ "$h|$m|$e" != "$harness|$model|$effort" ] \
    || die "the quota failure was recorded but task '$id''s own profile still reads as available; refusing to relaunch onto the same runtime"
  printf 'from=%s/%s to=%s/%s at=%s evidence=%s\n' "$harness" "${model:-default}" "$h" "${m:-default}" "$NOW" "$line" > "$marker" \
    || die "cannot write $marker; not relaunching without the once-only guard"
  note="The previous worker on $harness ${model:-default} stopped on a quota or usage-limit failure (\"$line\"). You replace it on $h ${m:-default} in the same local copy: read git status and git log to see the progress already made, then continue the task from the brief. Do not repeat finished steps."
  FM_HOME="$FM_HOME" "$SCRIPT_DIR/fm-control.sh" "$id" relaunch \
    --harness "$h" --model "${m:-default}" --effort "${e:-default}" --note "$note"
  rc=$?
  if [ "$rc" -eq 0 ]; then
    echo "quota-failover: task '$id' moved from $harness ${model:-default} to $h ${m:-default} after: $line"
  else
    echo "quota-failover: relaunching task '$id' onto $h ${m:-default} failed (exit $rc); not retrying" >&2
  fi
  exit "$rc"
}

case "${1:-}" in
  pick)
    shift
    parse_profile_flags "$@"
    choose "$HARNESS" "$MODEL" "$EFFORT" || exit $?
    printf '%s\n' "$CHOSEN"
    ;;
  record)
    shift
    parse_profile_flags "$@"
    record_failure "$HARNESS" "$MODEL" "$UNTIL" "${WHY:-recorded by firstmate}"
    ;;
  relaunch)
    [ "$#" -eq 2 ] || die "usage: fm-quota-failover.sh relaunch <task-id>" 2
    relaunch_task "$2"
    ;;
  *) usage >&2; exit 2 ;;
esac
