#!/usr/bin/env bash
# fm-reconcile-underway.sh - read-only classification of this home's underway
# work, with the exact guarded next command per task. It never mutates a task,
# copy, record, ref or the queue; the printed commands own every proof and gate
# (teardown's landed-work, clean and endpoint gates; restore's byte, generation
# and reservation binding), so a wrong classification refuses there instead of
# losing work. The /stow skill owns judgment and authority over these lines.
#
# Usage: FM_HOME=<home> fm-reconcile-underway.sh [--archive <state-dir>]...
#   --archive  a directory of archived task records (<id>.meta), such as one a
#              registration archive left; repeatable, never discovered.
# Inputs: In-flight queue rows, state/<id>.meta records (ship/scout) and
# state/<id>.git-worktree native reservations, joined by task id.
# Output, one tab-separated line per task: <id> <class> <next> <evidence>
# where <next> is `-` when no command applies. Classes:
#   captain-held   an open captain call (bin/fm-captain-hold.sh open); untouched.
#   landed         delivery evidence found; next is the guarded teardown (or the
#                  queue close for a row-only delivered scout). Generated
#                  leftovers (build .cache node_modules __pycache__ .next out)
#                  are named as --preserve-untracked only for the caller to inspect first.
#   ongoing        live worker, or work still owed with its endpoint gone (next
#                  is the stuck-crewmate-recovery relaunch).
#   needs-captain  unlanded or awaiting-merge work only the captain can decide.
#   record-archived  a reservation without a record whose archive was found;
#                  next restores it; rerun afterwards to classify.
#   unretirable    no supported path (missing or ambiguous archive, unreadable copy).
#   stale-row      an In-flight row with no record, copy or report.
#   unknown        endpoint or PR state could not be read; nothing is proposed.
set -u
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { sed -n '9,12p' "$0" | sed 's/^# \{0,1\}//'; }
ARCHIVES=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --archive) [ "$#" -ge 2 ] && [ -d "$2" ] || { echo 'error: --archive needs a directory' >&2; exit 2; }; ARCHIVES+=("$2"); shift ;;
    --help|-h) usage; exit 0 ;;
    *) usage >&2; exit 2 ;;
  esac
  shift
done
[ -n "${FM_HOME:-}" ] || { echo 'error: FM_HOME must be explicit' >&2; exit 2; }
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-git-worktree-lib.sh
. "$SCRIPT_DIR/fm-git-worktree-lib.sh"
STATE="$FM_HOME/state"
DATA="$FM_HOME/data"
GENERATED=' build .cache node_modules __pycache__ .next out '

ROWS=$(FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-queue.sh" list --state in_flight --include-held --json 2>/dev/null \
  | python3 -c 'import json,sys
for t in json.load(sys.stdin)["tasks"]:
    print("%s\t%s" % (t["id"], t.get("kind") or ""))') || { echo 'error: cannot read In-flight queue rows' >&2; exit 1; }

emit() { printf '%s\t%s\t%s\t%s\n' "$1" "$2" "$3" "$4"; }
quote() { printf '%q' "$1"; }

# Untracked/ignored top-level leftovers, as `generated` and `other` lists.
leftovers() { # <copy>
  local line path base
  LEFT_GEN=() LEFT_OTHER=() LEFT_TRACKED=0
  while IFS= read -r -d '' line; do
    path=${line:3}; path=${path%/}
    case "$line" in
      '?? '*|'!! '*)
        base=${path##*/}
        case "$GENERATED" in *" $base "*) LEFT_GEN+=("$path") ;; *) LEFT_OTHER+=("$path") ;; esac ;;
      *) LEFT_TRACKED=1 ;;
    esac
  done < <(git -C "$1" status --porcelain=v1 -z --ignored=traditional --untracked-files=normal 2>/dev/null)
}

# Emits a landed line whose next command is the guarded teardown.
emit_teardown() { # <id> <copy> <evidence>
  local cmd p note=
  cmd="bin/fm-teardown.sh $(quote "$1")"
  LEFT_GEN=() LEFT_OTHER=() LEFT_TRACKED=0
  [ ! -d "$2" ] || leftovers "$2"
  for p in ${LEFT_GEN[@]+"${LEFT_GEN[@]}"}; do cmd="$cmd --preserve-untracked $(quote "$p")"; done
  [ "$LEFT_TRACKED" = 0 ] || note="tracked edits present; "
  [ "${#LEFT_GEN[@]}" = 0 ] || note="${note}inspect generated leftovers before preserving: ${LEFT_GEN[*]}; "
  [ "${#LEFT_OTHER[@]}" = 0 ] || note="${note}other leftovers refuse teardown: ${LEFT_OTHER[*]}; "
  emit "$1" landed "$cmd" "$note$3"
}

# Advisory local-only landing read; teardown_native_local_landed is the proof.
local_landed() { # <copy> <reservation-or-empty> <project>
  local ref base merges cherry
  base=$( [ -n "$2" ] && fm_git_worktree_field "$2" base 2>/dev/null ) || base=
  [ -n "$base" ] && [ "$(git -C "$1" rev-parse HEAD 2>/dev/null)" = "$base" ] && return 0
  ref=$( [ -n "$2" ] && fm_git_worktree_field "$2" source_ref 2>/dev/null ) || ref=
  case "$ref" in
    refs/heads/*) ;;
    *) ref=$(git -C "$3" symbolic-ref --quiet --short refs/remotes/origin/HEAD 2>/dev/null) && ref="refs/heads/${ref#origin/}" \
         || { git -C "$3" show-ref --verify --quiet refs/heads/main && ref=refs/heads/main; } || ref=refs/heads/master ;;
  esac
  git -C "$1" merge-base --is-ancestor HEAD "$ref" 2>/dev/null && return 0
  merges=$(git -C "$1" rev-list --merges "$ref..HEAD" -- 2>/dev/null) || return 1
  [ -z "$merges" ] || return 1
  cherry=$(git -C "$1" cherry "$ref" HEAD 2>/dev/null) || return 1
  [ -n "$cherry" ] && ! printf '%s\n' "$cherry" | grep -qv '^- '
}

classify_record() { # <id> <meta>
  local id=$1 meta=$2 kind mode wt proj backend target endpoint pr prstate crew res=
  kind=$(fm_meta_get "$meta" kind); mode=$(fm_meta_get "$meta" mode)
  wt=$(fm_meta_get "$meta" worktree); proj=$(fm_meta_get "$meta" project)
  [ -f "$STATE/$id.git-worktree" ] && res="$STATE/$id.git-worktree"
  backend=$(fm_backend_of_meta "$meta"); target=$(fm_backend_target_of_meta "$meta")
  endpoint=missing
  [ -z "$target" ] || endpoint=$(fm_backend_agent_state "$backend" "$target" 2>/dev/null)
  case "$endpoint" in alive|dead|missing) ;; *) emit "$id" unknown - "endpoint $endpoint"; return ;; esac
  if [ "$kind" = scout ]; then
    [ "$endpoint" = alive ] && { emit "$id" ongoing - 'scout worker live; report existence does not prove completion'; return; }
    if [ -f "$DATA/$id/report.md" ]; then
      emit_teardown "$id" "$wt" "scout report data/$id/report.md; teardown also needs the captain-call inventory"
    else emit "$id" ongoing "bin/fm-control.sh $(quote "$id") relaunch" 'scout endpoint gone before its report'
    fi
    return
  fi
  if [ "$mode" = local-only ]; then
    [ "$endpoint" = alive ] && { emit "$id" ongoing - 'local-only worker live; local history does not prove completion'; return; }
    if [ -d "$wt" ] && local_landed "$wt" "$res" "$proj"; then
      emit_teardown "$id" "$wt" 'local work is in local history'
    elif [ -d "$wt" ]; then
      emit "$id" needs-captain - "unlanded local-only commits on $(git -C "$wt" rev-parse --abbrev-ref HEAD 2>/dev/null): approve bin/fm-merge-local.sh, or decide teardown --retain-branch"
    else emit "$id" unretirable - 'local-only copy missing'
    fi
    return
  fi
  pr=$(fm_meta_get "$meta" pr)
  if [ -z "$pr" ]; then
    if [ "$endpoint" = alive ]; then emit "$id" ongoing - 'worker live, no PR yet'
    else emit "$id" ongoing "bin/fm-control.sh $(quote "$id") relaunch" 'endpoint gone before any PR'
    fi
    return
  fi
  prstate=$( (cd "${wt:-$proj}" 2>/dev/null || cd "$proj" || exit 1; gh pr view "$pr" --json state --jq .state) 2>/dev/null) || prstate=
  case "$prstate" in
    MERGED)
      [ "$endpoint" = alive ] && { emit "$id" ongoing - "merged $pr; live worker may have subsequent work"; return; }
      emit_teardown "$id" "$wt" "merged $pr" ;;
    OPEN)
      if [ "$endpoint" = alive ]; then emit "$id" ongoing - "worker live; $pr open"; return; fi
      crew=$(FM_HOME="$FM_HOME" FM_CREW_STATE_NO_FORGE=1 bash "$SCRIPT_DIR/fm-crew-state.sh" "$id" 2>/dev/null | sed -n 's/^state: \([a-z]*\).*/\1/p')
      if [ "$crew" = 'done' ]; then emit "$id" needs-captain - "$pr ready; merge decision"
      else emit "$id" ongoing "bin/fm-control.sh $(quote "$id") relaunch" "endpoint gone with $pr open (current state ${crew:-unknown})"
      fi ;;
    CLOSED) emit "$id" needs-captain - "$pr closed unmerged" ;;
    *) emit "$id" unknown - "PR $pr state unreadable" ;;
  esac
}

classify_reservation() { # <id> <row-kind> - reservation without a record
  local id=$1 dir found=() sum gen target
  for dir in ${ARCHIVES[@]+"${ARCHIVES[@]}"}; do
    [ -f "$dir/$id.meta" ] && [ ! -L "$dir/$id.meta" ] && found+=("$dir/$id.meta")
  done
  case "${#found[@]}" in
    0)
      if [ "$2" = scout ] && [ -f "$DATA/$id/report.md" ]; then
        classify_row "$id" "$2" 'copy and reservation stay preserved'
      else emit "$id" unretirable - 'native reservation without task record; no archive given holds it'
      fi ;;
    1)
      if ! sum=$(python3 -c 'import hashlib,sys; print(hashlib.sha256(open(sys.argv[1], "rb").read()).hexdigest())' "${found[0]}" 2>/dev/null); then
        emit "$id" unretirable - "cannot hash archived record ${found[0]}"
        return
      fi
      gen=$(fm_meta_get "${found[0]}" spawn_gen); target=$(fm_backend_target_of_meta "${found[0]}")
      emit "$id" record-archived \
        "FM_HOME=$(quote "$FM_HOME") bin/fm-task-record-restore.sh $(quote "$id") $(quote "${found[0]}") $sum $(quote "$gen") $(quote "$target")" \
        "archived $(fm_meta_get "${found[0]}" kind) record; restore verifies bytes, generation, endpoint and reservation" ;;
    *) emit "$id" unretirable - "ambiguous archives: ${found[*]}" ;;
  esac
}

classify_row() { # <id> <kind> [preservation-note] - In-flight row without a record
  local rel
  if [ "$2" = scout ] && [ -f "$DATA/$1/report.md" ]; then
    if ! FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-captain-hold.sh" verify "$1" >/dev/null 2>&1; then
      emit "$1" needs-captain - "scout report needs captain-call inventory verification; ${3:-no task record or reservation}"
      return
    fi
    rel="${DATA##*/}/$1/report.md" # relative to the backlog root, as teardown records it
    emit "$1" landed "bin/fm-queue.sh done $(quote "$1") --report $(quote "$rel")" "delivered scout report; ${3:-no task record or reservation}"
  else
    emit "$1" stale-row - 'In-flight row has no record, copy or report'
  fi
}

ids=$( { printf '%s\n' "$ROWS" | cut -f1
  for f in "$STATE"/*.meta "$STATE"/*.git-worktree; do [ -e "$f" ] || continue; f=${f##*/}; printf '%s\n' "${f%.*}"; done
} | sed '/^$/d' | sort -u)
while IFS= read -r id; do
  if [ -z "$id" ] || ! fm_task_id_path_safe "$id"; then continue; fi
  meta="$STATE/$id.meta"
  if [ -f "$meta" ]; then
    case "$(fm_meta_get "$meta" kind)" in ship|scout) ;; *) continue ;; esac
  fi
  if FM_HOME="$FM_HOME" bash "$SCRIPT_DIR/fm-captain-hold.sh" open "$id" >/dev/null 2>&1; then
    emit "$id" captain-held - 'open captain call; leave untouched'
  elif [ -f "$meta" ]; then classify_record "$id" "$meta"
  elif [ -f "$STATE/$id.git-worktree" ]; then classify_reservation "$id" "$(printf '%s\n' "$ROWS" | awk -F '\t' -v id="$id" '$1 == id {print $2}')"
  else classify_row "$id" "$(printf '%s\n' "$ROWS" | awk -F '\t' -v id="$id" '$1 == id {print $2}')"
  fi
done <<< "$ids"
