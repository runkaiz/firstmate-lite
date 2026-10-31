#!/usr/bin/env bash
# Restore one archived native task record, without touching its endpoint/copy.
# Usage: fm-task-record-restore.sh <id> <archive> <sha256> <spawn-gen> <endpoint>
# All five arguments are explicit operator assertions, not archive discovery.
# The digest binds the exact archived bytes; generation and endpoint bind the
# original contract. Native reservation identity must agree independently.
# Existing metadata, pending retirement, symlinks and ambiguous fields refuse.
# The task control, project allocation and metadata locks serialize publication
# with ordinary lifecycle operations. Teardown still owns every removal gate.
set -eu
SCRIPT_DIR=$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)
usage() { echo 'usage: fm-task-record-restore.sh <id> <archive> <sha256> <spawn-gen> <endpoint>'; }
if [ "$#" = 1 ] && [ "$1" = --help ]; then usage; exit 0; fi
# shellcheck source=bin/fm-backend.sh
. "$SCRIPT_DIR/fm-backend.sh"
# shellcheck source=bin/fm-pr-lib.sh
. "$SCRIPT_DIR/fm-pr-lib.sh"
# shellcheck source=bin/fm-git-worktree-lib.sh
. "$SCRIPT_DIR/fm-git-worktree-lib.sh"
# shellcheck source=bin/fm-wake-lib.sh
. "$SCRIPT_DIR/fm-wake-lib.sh"
# shellcheck source=bin/fm-lock-lib.sh
. "$SCRIPT_DIR/fm-lock-lib.sh"
refuse() { echo "REFUSED: archived task record: $*" >&2; exit 1; }
[ "$#" = 5 ] || { usage >&2; exit 2; }
ID=$1 ARCHIVE=$2 DIGEST=$3 GENERATION=$4 ENDPOINT=$5
fm_task_id_path_safe "$ID" || refuse 'invalid task id'
[ -n "${FM_HOME:-}" ] || refuse 'FM_HOME must be explicit'
STATE="$FM_HOME/state"
META="$STATE/$ID.meta"
[ -d "$STATE" ] && [ ! -L "$STATE" ] || refuse 'unsafe state directory'
[ -f "$ARCHIVE" ] && [ ! -L "$ARCHIVE" ] || refuse 'archive must be a regular file'
TMP=$(umask 077; mktemp "$STATE/.$ID.restore.XXXXXXXX")
CONTROL=''
PROJECT_LOCK=''
META_LOCK=''
cleanup() {
  local rc=$?
  rm -f "$TMP"
  [ -z "$META_LOCK" ] || fm_lock_release "$META_LOCK"
  [ -z "$CONTROL" ] || fm_lock_release "$CONTROL"
  [ -z "$PROJECT_LOCK" ] || fm_lock_release "$PROJECT_LOCK"
  return "$rc"
}
trap cleanup EXIT
cp "$ARCHIVE" "$TMP"
python3 - "$TMP" "$DIGEST" <<'PY' || refuse 'archive digest does not match'
import hashlib, re, sys
assert re.fullmatch(r'[0-9a-f]{64}', sys.argv[2])
assert hashlib.sha256(open(sys.argv[1], 'rb').read()).hexdigest() == sys.argv[2]
PY
for key in project worktree allocator kind mode spawn_gen; do
  fm_git_worktree_field "$TMP" "$key" >/dev/null || refuse "ambiguous or missing $key"
done
[ "$(fm_meta_get "$TMP" allocator)" = git ] || refuse 'only native records are supported'
case "$(fm_meta_get "$TMP" kind)" in ship|scout) ;; *) refuse 'unsupported task kind' ;; esac
case "$(fm_meta_get "$TMP" mode)" in local-only|direct-PR|no-mistakes) ;; *) refuse 'unsupported delivery contract' ;; esac
[ "$(fm_meta_get "$TMP" spawn_gen)" = "$GENERATION" ] && [ -n "$GENERATION" ] || refuse 'generation mismatch'
case "$GENERATION" in .*|*[!A-Za-z0-9._-]*) refuse 'invalid generation' ;; esac
fm_backend_validate_task_endpoint "$TMP" "$ID" || refuse 'endpoint identity is invalid'
[ "$(fm_backend_target_of_meta "$TMP")" = "$ENDPOINT" ] && [ -n "$ENDPOINT" ] || refuse 'endpoint mismatch'
PROJECT=$(fm_meta_get "$TMP" project)
WORKTREE=$(fm_meta_get "$TMP" worktree)
lock=$(fm_treehouse_project_lock_path "$PROJECT") || refuse 'cannot resolve project lock'
fm_lock_try_acquire "$lock" || refuse 'project allocation is busy'
PROJECT_LOCK=$lock
lock="$STATE/.control-$ID.lock"
fm_lock_try_acquire "$lock" || refuse 'task lifecycle is busy'
CONTROL=$lock
lock=$(fm_meta_lock_path "$META") || refuse 'cannot resolve metadata lock'
fm_lock_try_acquire "$lock" || refuse 'task metadata is busy'
META_LOCK=$lock
[ ! -e "$META" ] && [ ! -L "$META" ] || refuse 'task record already exists'
[ ! -e "$STATE/$ID.backlog-close" ] && [ ! -L "$STATE/$ID.backlog-close" ] || refuse 'retirement is pending'
if [ -e "$STATE/$ID.busy-gen" ] || [ -L "$STATE/$ID.busy-gen" ]; then
  [ -f "$STATE/$ID.busy-gen" ] && [ ! -L "$STATE/$ID.busy-gen" ] || refuse 'unsafe busy generation'
  archived_busy=$(fm_git_worktree_field "$TMP" busy_gen) || refuse 'archive lacks exact busy generation'
  [ "$archived_busy" = "$(cat "$STATE/$ID.busy-gen")" ] || refuse 'busy generation mismatch'
fi
fm_git_worktree_identity "$STATE" "$ID" "$FM_HOME" "$PROJECT" "$WORKTREE" || refuse 'reservation identity mismatch'
# A hard link is an exclusive publish: even a non-cooperating writer cannot
# have its record replaced. Removing the staging link leaves an ordinary file.
ln "$TMP" "$META" || refuse 'task record appeared during restoration'
rm "$TMP"
echo "Restored $ID metadata with sha256=$DIGEST; endpoint and copy unchanged."
