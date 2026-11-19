#!/usr/bin/env bash
# Behavior tests for remote workers: bin/fm-remote-task.sh, the herdr-remote
# adapter (bin/backends/herdr-remote.sh), and the fm-brief/fm-spawn/fm-send/
# fm-crew-state hooks, driven through their executables with stand-ins:
#   * ssh runs the remote script locally with HOME set to a fake remote home and
#     refuses everything while an outage flag exists;
#   * herdr keeps a tiny JSON model of one remote server (workspaces, tabs,
#     panes, focus), runs a typed launch line in the background, and can lose a
#     create response or hide focus;
#   * gh models one repository's PRs and can lose a create response.
# Pins: exactly-once status import across crash points, continuity breaks,
# placement and acknowledgement, the outage policy, lost-response adoption,
# endpoint identity, the focus rule, the cleanup proof and resumable removal,
# and the publication gates.
# Case setup snippets are single-quoted on purpose: proof_refuses evals them.
# shellcheck disable=SC2016
set -u

# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

ROOT=$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd -P)
T=$(fm_test_tmproot fm-remote-task)
HOMEDIR="$T/home"
REMOTE_HOME="$T/remote-home"
STUBS="$T/stubs"
REMOTE_STUBS="$T/remote-stubs"
HERDR_DB="$T/herdr"
mkdir -p "$HOMEDIR/state" "$HOMEDIR/data" "$HOMEDIR/config" "$REMOTE_HOME" "$STUBS" "$REMOTE_STUBS" "$HERDR_DB" "$T/copies"
MID=0123456789abcdef0123456789abcdef
printf '%s pegasus\n' "$MID" > "$HOMEDIR/config/remote-machines"
printf 'git\n' > "$HOMEDIR/config/worktree-allocator"
printf '%s\n' "$T/copies" > "$HOMEDIR/config/git-worktree-root"
printf 'manual\n' > "$HOMEDIR/config/backlog-backend"
export FM_HOME="$HOMEDIR" FAKE_REMOTE_HOME="$REMOTE_HOME" FAKE_HERDR_DB="$HERDR_DB" FAKE_MID="$MID"
export FAKE_REMOTE_PATH="$REMOTE_STUBS:$PATH" FM_REMOTE_PROCS_FRESH_SECS=600
git config --global user.email >/dev/null 2>&1 || export GIT_AUTHOR_NAME=t GIT_AUTHOR_EMAIL=t@t GIT_COMMITTER_NAME=t GIT_COMMITTER_EMAIL=t@t

# --- stand-ins ---------------------------------------------------------------
cat > "$STUBS/ssh" <<'SH'
#!/usr/bin/env bash
while [ $# -gt 0 ]; do case "$1" in -o|-p|-i|-l) shift 2 ;; -*) shift ;; *) break ;; esac; done
shift
case "$*" in *git-upload-pack*) [ ! -e "$FAKE_REMOTE_HOME/.fetch-fails" ] || exit 255 ;; esac
[ ! -e "$FAKE_REMOTE_HOME/.down" ] || { echo "ssh: connect to host: Operation timed out" >&2; exit 255; }
mkdir -p "$FAKE_REMOTE_HOME/tmp"
if [ "$*" = '/bin/bash -s' ]; then
  {
    cat <<'HOOK'
git() {
  if [ "$*" = 'rev-parse --verify --quiet refs/heads/fm/r1' ] && [ -e "$HOME/.snapshot-race" ]; then
    rm -f "$HOME/.snapshot-race"
    command git "$@" || return $?
    command git commit -q --allow-empty -m snapshot-race || return $?
    command git rev-parse HEAD > "$HOME/snapshot-race-head"
    printf 'done [at=2]: snapshot race completion\n' >> "$HOME/firstmate-remote/tasks/r1/channel/status"
  else
    command git "$@"
  fi
}
HOOK
    cat
  } | HOME=$FAKE_REMOTE_HOME TMPDIR=$FAKE_REMOTE_HOME/tmp PATH=$FAKE_REMOTE_PATH bash -s
  rc=$?
  if [ -e "$FAKE_REMOTE_HOME/.hold-copy" ]; then
    touch "$FAKE_REMOTE_HOME/.copy-ready"
    for i in $(seq 1 700); do
      [ ! -e "$FAKE_REMOTE_HOME/.release-copy" ] || break
      sleep 0.01
    done
  fi
  exit "$rc"
else
  HOME=$FAKE_REMOTE_HOME TMPDIR=$FAKE_REMOTE_HOME/tmp PATH=$FAKE_REMOTE_PATH exec bash -c "$*"
fi
SH
cat > "$REMOTE_STUBS/claude" <<'SH'
#!/usr/bin/env bash
while :; do sleep 1; done
SH
cat > "$STUBS/herdr" <<'SH'
#!/usr/bin/env bash
db=$FAKE_HERDR_DB/state.json
log=$FAKE_HERDR_DB/log
[ -f "$db" ] || printf '%s\n' '{"n":1,"ws":[{"workspace_id":"w1","label":"~","focused":true}],"tabs":[{"tab_id":"w1:t1","workspace_id":"w1","label":"1","focused":true}],"panes":[{"pane_id":"w1:p1","tab_id":"w1:t1","workspace_id":"w1","cwd":"/"}]}' > "$db"
upd() { local t; t=$(mktemp "$db.XXXX"); jq "$@" "$db" > "$t" && mv "$t" "$db"; }
if [ "$1" = machine ] && [ "$2" = list ]; then
  printf '[{"id":"%s","label":"pegasus","target":"pegasus","session":"default","enabled":true,"selected":false}]\n' "$FAKE_MID"; exit 0
fi
if [ "$1" = session ] && [ "$2" = list ]; then echo '{"sessions":[{"name":"default"}]}'; exit 0; fi
[ "$1" = --machine ] && [ "$2" = "$FAKE_MID" ] || { echo "unexpected herdr call: $*" >&2; exit 2; }
shift 2
printf '%s\n' "$*" >> "$log"
[ ! -e "$FAKE_HERDR_DB/down" ] || { echo '{"error":{"code":"remote_unavailable"}}'; exit 1; }
case "$1 $2" in
  "workspace list")
    if [ -e "$FAKE_HERDR_DB/nofocus" ]; then jq -c '{result:{workspaces:[.ws[]|.focused=false]}}' "$db"; else jq -c '{result:{workspaces:.ws}}' "$db"; fi ;;
  "workspace rename") upd --arg w "$3" --arg l "$4" '(.ws[]|select(.workspace_id==$w)|.label) = $l'; echo '{"result":{}}' ;;
  "workspace create")
    shift 2; label= cwd=
    while [ $# -gt 0 ]; do case "$1" in --label) label=$2; shift 2 ;; --cwd) cwd=$2; shift 2 ;; --env) shift 2 ;; *) shift ;; esac; done
    n=$(jq .n "$db"); ws="w$((n + 1))"
    upd --arg ws "$ws" --arg l "$label" --arg c "$cwd" '.n += 1 | .ws += [{workspace_id:$ws,label:$l,focused:false}] | .tabs += [{tab_id:($ws+":t1"),workspace_id:$ws,label:"1",focused:true}] | .panes += [{pane_id:($ws+":p1"),tab_id:($ws+":t1"),workspace_id:$ws,cwd:$c}]'
    [ ! -e "$FAKE_HERDR_DB/lose-create" ] || exit 1
    printf '{"result":{"workspace":{"workspace_id":"%s"},"tab":{"tab_id":"%s:t1"},"root_pane":{"pane_id":"%s:p1"}}}\n' "$ws" "$ws" "$ws" ;;
  "tab list")
    jq -c --arg w "$4" '{result:{tabs:[.tabs[]|select(.workspace_id==$w)]}}' "$db" ;;
  "tab create")
    shift 2; ws= label= cwd=
    while [ $# -gt 0 ]; do case "$1" in --workspace) ws=$2; shift 2 ;; --label) label=$2; shift 2 ;; --cwd) cwd=$2; shift 2 ;; --env) shift 2 ;; *) shift ;; esac; done
    n=$(jq .n "$db"); t="$ws:t$((n + 10))"; p="$ws:p$((n + 10))"
    upd --arg w "$ws" --arg t "$t" --arg p "$p" --arg l "$label" --arg c "$cwd" '.n += 1 | .tabs += [{tab_id:$t,workspace_id:$w,label:$l,focused:false}] | .panes += [{pane_id:$p,tab_id:$t,workspace_id:$w,cwd:$c}]'
    if [ -e "$FAKE_HERDR_DB/dup-create" ]; then
      upd --arg w "$ws" --arg t "$t" --arg p "$p" --arg l "$label" --arg c "$cwd" '.tabs += [{tab_id:($t+"b"),workspace_id:$w,label:$l,focused:false}] | .panes += [{pane_id:($p+"b"),tab_id:($t+"b"),workspace_id:$w,cwd:$c}]'
    fi
    [ ! -e "$FAKE_HERDR_DB/lose-create" ] || exit 1
    printf '{"result":{"tab":{"tab_id":"%s"},"root_pane":{"pane_id":"%s"}}}\n' "$t" "$p" ;;
  "tab rename") upd --arg t "$3" --arg l "$4" '(.tabs[]|select(.tab_id==$t)|.label) = $l'; echo '{"result":{}}' ;;
  "tab focus") upd --arg t "$3" '(.tabs[]|select(.tab_id==$t)) as $x | (.tabs[]|select(.workspace_id==$x.workspace_id)|.focused) |= false | (.tabs[]|select(.tab_id==$t)|.focused) = true'; echo '{"result":{}}' ;;
  "workspace focus") upd --arg w "$3" '(.ws[]|.focused) = false | (.ws[]|select(.workspace_id==$w)|.focused) = true'; echo '{"result":{}}' ;;
  "tab close")
    for pid in $(cat "$FAKE_HERDR_DB/pids.${3//:/_}" 2>/dev/null); do pkill -P "$pid" 2>/dev/null; kill "$pid" 2>/dev/null; done
    upd --arg t "$3" '.panes |= map(select(.tab_id != $t)) | .tabs |= map(select(.tab_id != $t)) | .tabs as $tabs | .ws |= map(select(.workspace_id as $w | any($tabs[]; .workspace_id == $w)))'
    echo '{"result":{}}' ;;
  "pane get")
    out=$(jq -c --arg p "$3" '[.panes[]|select(.pane_id==$p)] | if length==1 then {result:{pane:.[0]}} else empty end' "$db")
    if [ -n "$out" ]; then echo "$out"; else printf '{"error":{"code":"pane_not_found","message":"pane %s not found"}}\n' "$3"; exit 1; fi ;;
  "pane list") jq -c --arg w "$4" '{result:{panes:[.panes[]|select(.workspace_id==$w)]}}' "$db" ;;
  "pane run")
    tab=$(jq -r --arg p "$3" '.panes[]|select(.pane_id==$p)|.tab_id' "$db")
    ( cd / && HOME=$FAKE_REMOTE_HOME PATH=$FAKE_REMOTE_PATH exec bash -c "$4; exec sleep 100000" ) </dev/null >/dev/null 2>&1 &
    echo "$!" >> "$FAKE_HERDR_DB/pids.${tab//:/_}"
    echo '{"result":{}}' ;;
  "agent get") echo '{"result":{"agent":{"agent":"claude","agent_status":"idle"}}}' ;;
  "pane read")
    [ -e "$FAKE_HERDR_DB/control-ui" ] || { printf '\n'; exit 0; }
    text=$(cat "$FAKE_HERDR_DB/composer.${3//:/_}" 2>/dev/null)
    printf '  ╭────────────────────────╮\n  │ ❯ %-20s │\n  ╰──────── Composer ──────╯\n' "$text" ;;
  "pane send-text") printf '%s' "$4" > "$FAKE_HERDR_DB/composer.${3//:/_}"; echo '{"result":{}}' ;;
  "pane send-keys")
    f="$FAKE_HERDR_DB/composer.${3//:/_}"
    if [ "$4" = enter ]; then
      if [ "$(cat "$f" 2>/dev/null)" = /exit ] && [ ! -e "$FAKE_HERDR_DB/ignore-exit" ]; then
        tab=$(jq -r --arg p "$3" '.panes[]|select(.pane_id==$p)|.tab_id' "$db")
        for pid in $(cat "$FAKE_HERDR_DB/pids.${tab//:/_}" 2>/dev/null); do pkill -P "$pid" 2>/dev/null; done
      fi
      rm -f "$f"
    fi
    echo '{"result":{}}' ;;
  *) echo "{\"error\":{\"code\":\"unsupported\",\"message\":\"$*\"}}"; exit 1 ;;
esac
SH
chmod +x "$STUBS/ssh" "$STUBS/herdr" "$REMOTE_STUBS/claude"
export PATH="$STUBS:$PATH" FM_REMOTE_SSH="$STUBS/ssh"

cleanup_remote_fixture() {
  local f pid
  if [ -n "${COPY_PID:-}" ]; then
    touch "$REMOTE_HOME/.release-copy"
    kill "$COPY_PID" 2>/dev/null || true
    wait "$COPY_PID" 2>/dev/null || true
  fi
  for f in "$HERDR_DB"/pids.*; do
    [ -f "$f" ] || continue
    while IFS= read -r pid; do
      pkill -P "$pid" 2>/dev/null || true
      kill "$pid" 2>/dev/null || true
    done < "$f"
  done
  fm_test_cleanup
}
trap cleanup_remote_fixture EXIT

RT="$ROOT/bin/fm-remote-task.sh"
ST="$HOMEDIR/state"
sync_now() { "$RT" sync pegasus >>"$T/sync.log" 2>&1; }
hstate() { cat "$HERDR_DB/state.json"; }

FM_REAL_AWK=$(command -v awk)
FM_RACE_RECORD="$ST/concurrent.remote"
export FM_REAL_AWK FM_RACE_RECORD
printf 'status_offset=0\nincarnation=old\n' > "$FM_RACE_RECORD"
cat > "$STUBS/awk" <<'SH'
#!/usr/bin/env bash
last=
for arg in "$@"; do last=$arg; done
if [ "$last" = "$FM_RACE_RECORD" ]; then
  if [ "${FM_RACE_ROLE:-}" = first ]; then
    "$FM_REAL_AWK" "$@" || exit $?
    touch "$FM_RACE_RECORD.first-read"
    for i in $(seq 1 1000); do
      [ ! -e "$FM_RACE_RECORD.release" ] || exit 0
      sleep 0.01
    done
    exit 1
  fi
fi
exec "$FM_REAL_AWK" "$@"
SH
chmod +x "$STUBS/awk"
FM_RACE_ROLE=first bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr-remote; fm_remote_record_set "$FM_RACE_RECORD" incarnation=new' _ "$ROOT" &
WRITER_FIRST=$!
for i in $(seq 1 300); do [ ! -e "$FM_RACE_RECORD.first-read" ] || break; sleep 0.01; done
[ -e "$FM_RACE_RECORD.first-read" ] || fail 'first record writer did not reach its paused read'
bash -c '. "$1/bin/fm-backend.sh"; fm_backend_source herdr-remote; touch "$FM_RACE_RECORD.second-started"; fm_remote_record_set "$FM_RACE_RECORD" status_offset=120 && touch "$FM_RACE_RECORD.second-done"' _ "$ROOT" &
WRITER_SECOND=$!
for i in $(seq 1 300); do [ ! -e "$FM_RACE_RECORD.second-started" ] || break; sleep 0.01; done
[ -e "$FM_RACE_RECORD.second-started" ] || fail 'second record writer did not start'
for i in $(seq 1 100); do [ ! -e "$FM_RACE_RECORD.second-done" ] || break; sleep 0.01; done
touch "$FM_RACE_RECORD.release"
wait "$WRITER_FIRST" || fail 'first record update failed'
wait "$WRITER_SECOND" || fail 'second record update failed'
grep -qx 'status_offset=120' "$FM_RACE_RECORD" && grep -qx 'incarnation=new' "$FM_RACE_RECORD" || fail 'concurrent record updates lost a field'
rm -f "$STUBS/awk"
pass 'concurrent incarnation and cursor updates preserve both fields'

# A local-only project with one commit.
PROJ="$T/proj"
git init -q -b main "$PROJ"
git -C "$PROJ" commit -q --allow-empty -m base

# --- brief scaffold ----------------------------------------------------------
"$ROOT/bin/fm-brief.sh" r1 proj --mode local-only --machine pegasus >/dev/null || fail 'remote brief scaffold failed'
B="$HOMEDIR/data/r1/brief.md"
grep -qxF 'Remote machine: pegasus' "$B" || fail 'remote brief lacks its machine line'
grep -qF '"$HOME"/firstmate-remote/tasks/r1/channel/status' "$B" || fail 'remote brief status path is not on the remote machine'
! grep -q 'fm-fleet-ledger' "$B" || fail 'remote brief still calls this machine fleet ledger'
grep -q 'already on its branch' "$B" || fail 'remote brief still asks the worker to create its branch'
if "$ROOT/bin/fm-brief.sh" r9 proj --mode no-mistakes --machine pegasus >/dev/null 2>&1; then fail 'a no-mistakes remote brief was scaffolded'; fi
pass 'fm-brief --machine scaffolds remote paths and refuses no-mistakes'
sed -i.bak 's/{TASK}/do the pilot/; s/{FIRSTMATE_SPEC}/small change/' "$B"

for option in '--effort high' '--effort=default'; do
  # shellcheck disable=SC2086
  OUT=$("$ROOT/bin/fm-spawn.sh" r1 "$PROJ" --machine pegasus --mode local-only --yolo off $option 2>&1) && fail 'remote spawn accepted unsupported effort'
  case "$OUT" in *"unknown option '--effort"*) ;; *) fail "effort refusal was not explicit: $OUT" ;; esac
  [ ! -e "$ST/r1.remote" ] || fail 'unsupported effort provisioned a remote task'
done

# --- spawn ---------------------------------------------------------------------
OUT=$("$ROOT/bin/fm-spawn.sh" r1 "$PROJ" --machine pegasus --mode local-only --yolo off 2>&1) || fail "remote spawn failed: $OUT"
META="$ST/r1.meta"
grep -q '^backend=herdr-remote$' "$META" || fail 'spawn did not record backend=herdr-remote'
W=$(sed -n 's/^window=//p' "$META")
case "$W" in "$MID":w2:p1) ;; *) fail "unexpected remote window '$W'" ;; esac
RTASK="$REMOTE_HOME/firstmate-remote/tasks/r1"
[ -d "$RTASK/wt" ] && [ -f "$RTASK/launch.sh" ] && [ -f "$RTASK/channel/launch-brief.md" ] || fail 'remote task folder is incomplete'
[ -z "$(git -C "$RTASK/wt" remote)" ] || fail 'remote copy has a git remote'
[ "$(git -C "$RTASK/wt" symbolic-ref --short HEAD)" = fm/r1 ] || fail 'remote copy is not on the task branch'
grep -qF "$RTASK/channel/inbox" "$RTASK/channel/launch-brief.md" || fail 'launch brief does not name the remote inbox'
jq -e --arg p "$RTASK/wt" --arg c "$RTASK/channel" '.projects[$p].hasTrustDialogAccepted == true and .projects[$c].hasTrustDialogAccepted == true' "$REMOTE_HOME/.claude.json" >/dev/null || fail 'remote Claude trust was not registered for the copy and its channel'
[ "$(hstate | jq -r '.ws[]|select(.focused)|.workspace_id')" = w1 ] && [ "$(hstate | jq -r '.tabs[]|select(.focused and .workspace_id=="w1")|.tab_id')" = w1:t1 ] || fail 'the captain focus moved during spawn'
grep -q "^tab rename w2:t1 fm-r1\." "$HERDR_DB/log" || fail 'the task tab does not carry its launch token'
pass 'spawn provisions the remote copy, trust, and token tab without moving focus'

# --- identity --------------------------------------------------------------------
( . "$ROOT/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$META" r1 ) >/dev/null 2>&1 || fail 'a valid remote endpoint record was refused'
sed "s/^window=.*/window=default:w2:p1/" "$META" > "$T/bad.meta"
if ( . "$ROOT/bin/fm-backend.sh"; fm_backend_validate_task_endpoint "$T/bad.meta" r1 ) >/dev/null 2>&1; then fail 'a remote record pointing at a local session key validated'; fi
pass 'a remote endpoint is keyed by its profile id and never by a local session'

# --- courier: status, commits, procs ------------------------------------------
sync_now
[ "$(sed -n 's/^state=//p' "$ST/.remote-link-$MID")" = reachable ] || fail "a reachable machine did not read reachable: $(cat "$T/sync.log")" 
grep -q '^agents=1$' "$ST/r1.remote-procs" || fail 'the remote process rows did not show the launched agent'
[ "$(. "$ROOT/bin/fm-backend.sh"; fm_backend_agent_state herdr-remote "$W")" = alive ] || fail 'a live remote agent did not read alive'
CS=$(FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" r1 2>/dev/null)
case "$CS" in *unsupported*|*"target gone"*) fail "crew state misread a reachable live remote task: $CS" ;; esac
[ -z "$(ls "$REMOTE_HOME/tmp" 2>/dev/null)" ] || fail "the courier left temporary files on the remote machine: $(ls "$REMOTE_HOME/tmp")"
printf 'working [at=1]: started\npartial' >> "$RTASK/channel/status"
sync_now
[ "$(cat "$ST/r1.status")" = 'working [at=1]: started' ] || fail "status import was not exactly the complete line: $(cat "$ST/r1.status")"
printf ' line\n' >> "$RTASK/channel/status"
git -C "$RTASK/wt" commit -q --allow-empty -m work1
SHA1=$(git -C "$RTASK/wt" rev-parse HEAD)
printf 'done [at=2]: ready in branch fm/r1\n' >> "$RTASK/channel/status"
sync_now
[ "$(tail -n1 "$ST/r1.status")" = 'done [at=2]: ready in branch fm/r1' ] || fail 'the later lines were not imported in order'
[ "$(grep -c started "$ST/r1.status")" = 1 ] || fail 'a status line was imported twice'
WT=$(sed -n 's/^worktree=//p' "$META")
[ "$(git -C "$WT" rev-parse HEAD)" = "$SHA1" ] && [ "$(git -C "$WT" symbolic-ref --short HEAD)" = fm/r1 ] || fail 'the landing copy was not fast-forwarded onto the named branch'
[ "$(git -C "$PROJ" rev-parse refs/firstmate/remote/r1)" = "$SHA1" ] || fail 'the custody ref does not hold the imported commit'
pass 'the courier imports commits before complete status lines, exactly once'
touch "$REMOTE_HOME/.snapshot-race"
sync_now
RACE_SHA=$(cat "$REMOTE_HOME/snapshot-race-head")
[ "$RACE_SHA" != "$SHA1" ] || fail 'snapshot interleaving did not create a later commit'
[ "$(git -C "$WT" rev-parse HEAD)" = "$SHA1" ] || fail 'snapshot interleaving did not retain the sampled branch head'
! grep -q 'snapshot race completion' "$ST/r1.status" || fail 'a status written after the commit sample arrived before its commit'
sync_now
[ "$(git -C "$WT" rev-parse HEAD)" = "$RACE_SHA" ] || fail 'the next snapshot did not import the later commit'
[ "$(grep -c 'snapshot race completion' "$ST/r1.status")" = 1 ] || fail 'the bounded snapshot lost or repeated completion'
SHA1=$RACE_SHA
pass 'status snapshots exclude lines written after their sampled commit'

"$ROOT/bin/fm-send.sh" r1 'acknowledge during fetch failure' 2>/dev/null
sync_now
ACK_MSG=$(ls "$ST/r1.inbox"/*.msg); ACK_NAME=${ACK_MSG##*/}
mv "$RTASK/channel/inbox/$ACK_NAME" "$RTASK/channel/inbox/handled/$ACK_NAME"
"$ROOT/bin/fm-send.sh" r1 'place during fetch failure' 2>/dev/null
PLACE_MSG=$(ls "$ST/r1.inbox"/*.msg | tail -n1); PLACE_NAME=${PLACE_MSG##*/}
OFF=$(sed -n 's/^status_offset=//p' "$ST/r1.remote")
git -C "$RTASK/wt" commit -q --allow-empty -m work2
SHA2=$(git -C "$RTASK/wt" rev-parse HEAD)
printf 'done [at=2]: ready after transport recovery\n' >> "$RTASK/channel/status"
touch "$REMOTE_HOME/.fetch-fails"
rm -f "$ST/r1.remote-procs"
sync_now
[ "$(sed -n 's/^status_offset=//p' "$ST/r1.remote")" = "$OFF" ] || fail 'failed commit custody advanced the status cursor'
[ "$(git -C "$WT" rev-parse HEAD)" = "$SHA1" ] || fail 'failed fetch advanced the landing copy'
! grep -q 'ready after transport recovery' "$ST/r1.status" || fail 'completion arrived before commit custody'
grep -q '^commit:' "$ST/r1.remote-alert" || fail 'failed custody did not record its condition'
grep -q '^agents=1$' "$ST/r1.remote-procs" || fail 'failed custody suppressed fresh process evidence'
[ -f "$ST/r1.inbox/handled/$ACK_NAME" ] && [ ! -e "$ACK_MSG" ] || fail 'failed custody suppressed an acknowledgement'
[ -e "$ST/r1.remote-placed/$PLACE_NAME" ] && [ -f "$RTASK/channel/inbox/$PLACE_NAME" ] || fail 'failed custody suppressed an instruction placement receipt'
mv "$RTASK/channel/inbox/$PLACE_NAME" "$RTASK/channel/inbox/handled/$PLACE_NAME"

rm -f "$REMOTE_HOME/.fetch-fails"
sync_now
[ "$(git -C "$WT" rev-parse HEAD)" = "$SHA2" ] || fail 'recovery did not import the commit'
[ "$(grep -c 'ready after transport recovery' "$ST/r1.status")" = 1 ] || fail 'recovery lost or repeated completion'
[ ! -e "$ST/r1.remote-alert" ] || fail 'successful custody left its resolved alert blocking cleanup'
pass 'failed commit custody defers completion and resolves its own alert after recovery'


for point in after-journal after-append after-receipt; do
  printf 'needs-decision [at=3] [key=journal-%s]: choose the continuation\n' "$point" >> "$RTASK/channel/status"
  sync_now
  printf 'working [at=3]: %s\n' "$point" >> "$RTASK/channel/status"
  FM_REMOTE_TEST_CRASH=$point "$RT" sync pegasus >/dev/null 2>&1
  rm -rf "$ST/.remote-sync-$MID.lock" "$ST/.remote-sync-$MID".lock* 2>/dev/null
  for l in "$ST"/*.lock "$ST"/.*.lock; do [ -e "$l" ] && rm -rf "$l"; done
  "$ROOT/bin/fm-send.sh" r1 --resolve-key "journal-$point" 'continue with the recorded plan' > "$T/resolve.out" 2>&1 || fail "local answer could not recover $point: $(cat "$T/resolve.out")"
  [ ! -e "$ST/r1.remote-journal" ] && [ ! -e "$ST/r1.remote-journal.bytes" ] || fail "local answer left its $point journal pending"
  python3 - "$ST/r1.status" "$point" <<'PYORDER' || fail 'local answer overtook or duplicated imported status'
import sys
lines = open(sys.argv[1]).read().splitlines()
point = sys.argv[2]
worker = [i for i, line in enumerate(lines) if line == f'working [at=3]: {point}']
answer = [i for i, line in enumerate(lines) if line.startswith('resolved ') and f'[key=journal-{point}]' in line]
assert len(worker) == len(answer) == 1 and worker[0] < answer[0]
PYORDER
  sync_now
  [ "$(grep -c "working \[at=3\]: $point" "$ST/r1.status")" = 1 ] || fail "a crash $point lost or repeated the line"
  for msg in "$RTASK"/channel/inbox/*.msg; do
    [ -f "$msg" ] && mv "$msg" "$RTASK/channel/inbox/handled/"
  done
  sync_now
done
pass 'local answers recover every interrupted import before appending their close events'
start_held_copy() {
  rm -f "$REMOTE_HOME/.copy-ready" "$REMOTE_HOME/.release-copy"
  touch "$REMOTE_HOME/.hold-copy"
  "$RT" sync pegasus >> "$T/sync.log" 2>&1 &
  COPY_PID=$!
  for i in $(seq 1 400); do [ ! -e "$REMOTE_HOME/.copy-ready" ] || break; sleep 0.01; done
  [ -e "$REMOTE_HOME/.copy-ready" ] || fail 'the status response did not reach the transport pause'
}
finish_held_copy() {
  rm -f "$REMOTE_HOME/.hold-copy"
  touch "$REMOTE_HOME/.release-copy"
  wait "$COPY_PID" || fail 'the held courier pass failed'
  COPY_PID=
}
set_cursor_field() {
  bash -c '. "$1/bin/fm-backend.sh"; . "$1/bin/fm-wake-lib.sh"; fm_backend_source herdr-remote; lock="$2/.remote-import-r1.lock"; fm_lock_acquire_wait "$lock" || exit 1; rc=0; fm_remote_record_set "$2/r1.remote" "$3=$4" || rc=$?; fm_lock_release "$lock"; exit "$rc"' _ "$ROOT" "$ST" "$1" "$2"
}
printf 'needs-decision [at=3] [key=cursor-race]: choose the continuation\n' >> "$RTASK/channel/status"
sync_now
printf 'needs-decision [at=3] [key=cursor-race]: journal recovery request\n' >> "$RTASK/channel/status"
FM_REMOTE_TEST_CRASH=after-journal "$RT" sync pegasus >/dev/null 2>&1
for l in "$ST"/*.lock "$ST"/.*.lock; do [ -e "$l" ] && rm -rf "$l"; done
printf 'working [at=3]: after concurrent journal recovery\n' >> "$RTASK/channel/status"
start_held_copy
"$ROOT/bin/fm-send.sh" r1 --resolve-key cursor-race 'continue after recovery' > "$T/resolve.out" 2>&1 || fail "answer during a fetched response failed: $(cat "$T/resolve.out")"
RECOVERED_OFFSET=$(sed -n 's/^status_offset=//p' "$ST/r1.remote")
[ ! -e "$ST/r1.remote-journal" ] || fail 'the concurrent answer did not recover its journal'
finish_held_copy
[ "$(sed -n 's/^status_offset=//p' "$ST/r1.remote")" = "$RECOVERED_OFFSET" ] || fail 'a stale response advanced the recovered cursor'
[ "$(grep -c 'journal recovery request' "$ST/r1.status")" = 1 ] || fail 'a stale response duplicated the recovered decision'
! grep -q 'after concurrent journal recovery' "$ST/r1.status" || fail 'a stale response was partially applied'
[ ! -e "$ST/r1.remote-alert" ] || fail 'concurrent recovery caused a false continuity alert'
sync_now
[ "$(grep -c 'after concurrent journal recovery' "$ST/r1.status")" = 1 ] || fail 'the next pass did not deliver the remaining status once'
OPEN=$(bash -c '. "$1/bin/fm-classify-lib.sh"; status_open_decisions "$2"' _ "$ROOT" "$ST/r1.status")
case "$OPEN" in *cursor-race*) fail 'a stale response reopened an answered decision' ;; esac
for msg in "$RTASK"/channel/inbox/*.msg; do [ -f "$msg" ] && mv "$msg" "$RTASK/channel/inbox/handled/"; done
sync_now
for field in status_prefix status_gen; do
  saved=$(sed -n "s/^$field=//p" "$ST/r1.remote")
  if [ "$field" = status_prefix ]; then changed=$(printf '%064d' 0); else changed=0000000000000000; fi
  [ "$changed" != "$saved" ] || fail 'the cursor change fixture is vacuous'
  printf 'working [at=3]: stale %s response\n' "$field" >> "$RTASK/channel/status"
  start_held_copy
  set_cursor_field "$field" "$changed" || fail 'could not advance the cursor representation during fetch'
  finish_held_copy
  ! grep -q "stale $field response" "$ST/r1.status" || fail "a mismatched $field response was applied"
  [ "$(sed -n "s/^$field=//p" "$ST/r1.remote")" = "$changed" ] || fail "stale bytes overwrote the committed $field"
  set_cursor_field "$field" "$saved" || fail 'could not restore the fixture cursor'
  sync_now
  [ "$(grep -c "stale $field response" "$ST/r1.status")" = 1 ] || fail "a fresh $field response was lost or duplicated"
done
pass 'fetched status stays bound to its original cursor across concurrent recovery'

printf 'working: local task\n' > "$ST/local-append.status"
APPEND_RC=0
bash -c '. "$1/bin/fm-wake-lib.sh"; fm_wake_status_append_self_announced "$2" "$2/local-append.status" "resolved [key=local]: acknowledged"' _ "$ROOT" "$ST" || APPEND_RC=$?
[ "$APPEND_RC" -le 1 ] || fail 'the ordinary local status append failed'
[ "$(grep -c '^resolved .*\[key=local\]' "$ST/local-append.status")" = 1 ] || fail 'ordinary local append lost or repeated its event'


cp "$RTASK/channel/status" "$T/status.save"
head -n1 "$T/status.save" > "$RTASK/channel/status"
OFF=$(sed -n 's/^status_offset=//p' "$ST/r1.remote")
sync_now
grep -q 'replaced or shortened' "$ST/r1.remote-alert" || fail 'a shortened remote status log did not raise a continuity alert'
[ "$(sed -n 's/^status_offset=//p' "$ST/r1.remote")" = "$OFF" ] || fail 'the status offset moved after a continuity break'
cp "$T/status.save" "$RTASK/channel/status"
sync_now
grep -q 'replaced or shortened' "$ST/r1.remote-alert" || fail 'successful commit custody cleared an unresolved continuity alert'
rm -f "$ST/r1.remote-alert"
pass 'a replaced or shortened remote status log stops import and keeps the offset'

# --- instructions -------------------------------------------------------------
: > "$HERDR_DB/log"
"$ROOT/bin/fm-send.sh" r1 "first instruction" 2> "$T/send.err" || fail 'fm-send to a remote task failed'
grep -q 'queued' "$T/send.err" || fail 'fm-send did not report queue-only delivery'
[ ! -s "$HERDR_DB/log" ] || fail 'fm-send touched the remote pane before placement'
REC=$(ls "$ST/r1.inbox"/*.msg); NAME=${REC##*/}
sync_now
[ -f "$RTASK/channel/inbox/$NAME" ] && [ -d "$RTASK/channel/inbox/.placed/$NAME" ] || fail 'the courier did not place the instruction'
[ -e "$ST/r1.remote-placed/$NAME" ] || fail 'placement was not recorded locally'
grep -q '^agent get' "$HERDR_DB/log" || fail 'no doorbell was attempted after confirmed placement'
[ ! -e "$ST/r1.inbox/.ring-state" ] || fail 'a doorbell that could not be sent spent ladder budget'
mv "$RTASK/channel/inbox/$NAME" "$RTASK/channel/inbox/handled/$NAME"
sync_now
[ -f "$ST/r1.inbox/handled/$NAME" ] && [ ! -e "$REC" ] || fail 'the remote acknowledgement did not move the local record to handled'
[ ! -e "$RTASK/channel/inbox/$NAME" ] || fail 'an acknowledged instruction was placed again'
# A receipt with a leftover temporary file finishes once; a receipt with no copy is an anomaly.
"$ROOT/bin/fm-send.sh" r1 "second" 2>/dev/null; REC2=$(ls "$ST/r1.inbox"/*.msg); N2=${REC2##*/}
mkdir "$RTASK/channel/inbox/.placed/$N2"; printf 'second' > "$RTASK/channel/inbox/.tmp-$N2"
sync_now
[ -f "$RTASK/channel/inbox/$N2" ] && [ ! -e "$RTASK/channel/inbox/.tmp-$N2" ] || fail 'an interrupted placement did not finish its rename'
mv "$RTASK/channel/inbox/$N2" "$RTASK/channel/inbox/handled/$N2"; sync_now
"$ROOT/bin/fm-send.sh" r1 "third" 2>/dev/null; REC3=$(ls "$ST/r1.inbox"/*.msg); N3=${REC3##*/}
mkdir "$RTASK/channel/inbox/.placed/$N3"
sync_now
[ ! -e "$RTASK/channel/inbox/$N3" ] || fail 'a receipt without a copy was placed again'
grep -q "$N3" "$ST/r1.remote-alert" || fail 'a receipt without a copy was not reported'
rm -f "$ST/r1.remote-alert"; mv "$REC3" "$ST/r1.inbox/handled/"
pass 'instructions are queued, placed once, rung after placement, and never resurrected'

# --- outage -------------------------------------------------------------------
printf 'done [at=4]: ready in branch fm/r1\n' >> "$RTASK/channel/status"; sync_now
touch "$REMOTE_HOME/.down"
sync_now
[ "$(sed -n 's/^state=//p' "$ST/.remote-link-$MID")" = unreachable ] || fail 'an ssh failure did not read unreachable'
[ "$(. "$ROOT/bin/fm-backend.sh"; fm_backend_agent_state herdr-remote "$W")" = unreadable ] || fail 'an unreachable machine read as anything but unreadable'
CS=$(FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" r1 2>/dev/null)
case "$CS" in "state: done"*unknown*|"state: done"*"not proof of death"*) ;; *) fail "crew state masked the worker's done line during an outage: $CS" ;; esac
if "$RT" retire r1 prepare >/dev/null 2>&1; then fail 'cleanup ran while the machine was unreachable'; fi
[ -f "$META" ] && [ -d "$RTASK/wt" ] || fail 'a refused cleanup changed records'
if "$ROOT/bin/fm-control.sh" r1 interrupt >/dev/null 2>&1; then fail 'interrupt ran during an outage'; fi
if "$ROOT/bin/fm-control.sh" r1 exit >/dev/null 2>&1; then fail 'exit claimed a stopped worker during an outage'; fi
rm -f "$REMOTE_HOME/.down"; touch "$HERDR_DB/down"
sync_now
[ "$(sed -n 's/^state=//p' "$ST/.remote-link-$MID")" = herdr-unavailable ] || fail 'a down remote Herdr did not read herdr-unavailable'
rm -f "$HERDR_DB/down"; sync_now
pass 'an outage reads unknown, keeps the worker state, and refuses cleanup intact'

# --- server incarnation -----------------------------------------------------
LABEL=$(sed -n 's/^tab_label=//p' "$ST/r1.remote")
[ -n "$LABEL" ] || fail 'spawn did not record the tab launch-token label'
printf 'incarnation=999@restarted\n' >> "$ST/.remote-link-$MID"
herdr --machine "$MID" tab rename w2:t1 reused >/dev/null
if (. "$ROOT/bin/fm-backend.sh"; fm_backend_kill herdr-remote "$W") 2>/dev/null; then fail 'a close ran on a reused pane id after a server restart'; fi
hstate | jq -e '.tabs[]|select(.tab_id=="w2:t1")' >/dev/null || fail 'a reused tab was closed'
sync_now
: > "$HERDR_DB/log"
if (. "$ROOT/bin/fm-backend.sh"; fm_backend_capture herdr-remote "$W" 20) >/dev/null 2>&1; then fail 'capture read a reused personal pane'; fi
if (. "$ROOT/bin/fm-backend.sh"; fm_backend_visible_capture herdr-remote "$W") >/dev/null 2>&1; then fail 'visible capture read a reused personal pane'; fi
if (. "$ROOT/bin/fm-backend.sh"; fm_backend_target_exists herdr-remote "$W") >/dev/null 2>&1; then fail 'a reused pane was reported as the task target'; fi
[ "$(. "$ROOT/bin/fm-backend.sh"; fm_backend_composer_state herdr-remote "$W" 2>/dev/null)" = unknown ] || fail 'composer read a reused pane'
[ "$(. "$ROOT/bin/fm-backend.sh"; fm_backend_busy_state herdr-remote "$W" 2>/dev/null)" = unknown ] || fail 'activity read a reused pane'
[ "$(. "$ROOT/bin/fm-backend.sh"; fm_backend_agent_state herdr-remote "$W" 2>/dev/null)" = unreadable ] || fail 'reused pane inherited task process evidence'
FM_CREW_STATE_NO_FORGE=1 "$ROOT/bin/fm-crew-state.sh" r1 >/dev/null 2>&1
! grep -Eq '^(pane read|agent get)' "$HERDR_DB/log" || fail 'a task read reached an unrelated pane'
printf 'incarnation=999@restarted\n' >> "$ST/.remote-link-$MID"
herdr --machine "$MID" tab rename w2:t1 "$LABEL" >/dev/null
(. "$ROOT/bin/fm-backend.sh"; fm_backend_source herdr-remote; fm_remote_identity_ok "$W") || fail 'a restarted server with the token intact was refused'
grep -q '^incarnation=999@restarted$' "$ST/r1.remote" || fail 'a proven token match did not re-bind the incarnation'
pass 'after a remote server restart only a launch-token match lets a mutation proceed'

# --- focus rule ---------------------------------------------------------------
herdr --machine "$MID" workspace focus w2 >/dev/null
herdr --machine "$MID" tab focus w2:t1 >/dev/null
if (. "$ROOT/bin/fm-backend.sh"; fm_backend_kill herdr-remote "$W") 2>/dev/null; then fail 'the focused remote tab was closed'; fi
herdr --machine "$MID" workspace focus w1 >/dev/null
touch "$HERDR_DB/nofocus"
if (. "$ROOT/bin/fm-backend.sh"; fm_backend_kill herdr-remote "$W") 2>/dev/null; then fail 'a close ran with unreadable focus'; fi
rm -f "$HERDR_DB/nofocus"
hstate | jq -e --arg p "${W#*:}" '.panes[]|select(.pane_id==$p)' >/dev/null || fail 'a deferred close removed the pane'
pass 'a close is deferred on the focused tab or unreadable focus'

touch "$HERDR_DB/control-ui"
OUT=$(FM_CONTROL_EXIT_WAIT=1 "$ROOT/bin/fm-control.sh" r1 interrupt 2>&1) || fail "remote interrupt failed: $OUT"
case "$OUT" in *interrupt-delivered*verified=agent-alive*) ;; *) fail "interrupt did not prove the agent remained running: $OUT" ;; esac
git -C "$RTASK/wt" commit -q --allow-empty -m control-without-fetch
printf 'working [at=4]: control while fetch unavailable\n' >> "$RTASK/channel/status"
touch "$REMOTE_HOME/.fetch-fails"
touch "$HERDR_DB/ignore-exit"
if FM_CONTROL_EXIT_WAIT=1 "$ROOT/bin/fm-control.sh" r1 exit > "$T/control.out" 2>&1; then fail 'exit claimed success while the remote agent remained running'; fi
[ "$(. "$ROOT/bin/fm-backend.sh"; fm_backend_agent_state herdr-remote "$W")" = alive ] || fail 'the unconfirmed exit test did not keep its agent running'
rm -f "$HERDR_DB/ignore-exit"
"$ROOT/bin/fm-control.sh" r1 exit > "$T/control.out" 2>&1 || fail "remote exit failed: $(cat "$T/control.out")"
grep -q '^stopped r1 ' "$T/control.out" || fail 'exit did not confirm the remote agent stopped'
grep -q '^agents=0$' "$ST/r1.remote-procs" || fail 'exit used a stale process observation'
"$ROOT/bin/fm-control.sh" r1 relaunch --note 'Continue after the controlled stop' > "$T/control.out" 2>&1 || fail "remote control relaunch failed: $(cat "$T/control.out")"
grep -q '^agents=1$' "$ST/r1.remote-procs" || fail 'control relaunch did not observe the replacement agent'
grep -q 'Continue after the controlled stop' "$RTASK"/channel/inbox/*.msg || fail 'the replacement did not receive its progress note'
rm -f "$REMOTE_HOME/.fetch-fails"
sync_now
pass 'remote controls interrupt, confirm exit with fresh observations, and relaunch with the progress note'

# --- crash and relaunch ------------------------------------------------------
if "$ROOT/bin/fm-control.sh" r1 relaunch --harness codex --note 'unsupported' >/dev/null 2>&1; then fail 'remote controls accepted an unsupported runtime override'; fi
if "$ROOT/bin/fm-spawn.sh" r1 --relaunch --effort high >/dev/null 2>&1; then fail 'direct remote relaunch silently ignored effort'; fi
GEN1=$(awk '{print $2}' "$RTASK/channel/pane.pid")
if "$RT" relaunch r1 >/dev/null 2>&1; then fail 'a relaunch ran over a live agent'; fi
pkill -P "$(awk '{print $1}' "$RTASK/channel/pane.pid")"
sleep 2; sync_now
grep -q '^agents=0$' "$ST/r1.remote-procs" || fail 'the remote rows still show an agent after it ended'
[ "$(. "$ROOT/bin/fm-backend.sh"; fm_backend_agent_state herdr-remote "$W")" = dead ] || fail 'an agent-free remote pane did not read dead'
"$ROOT/bin/fm-spawn.sh" r1 --relaunch > "$T/relaunch.out" 2>&1 || fail "relaunch into the same copy failed: $(cat "$T/relaunch.out")"
[ "$(awk '{print $2}' "$RTASK/channel/pane.pid")" != "$GEN1" ] || fail 'the relaunch did not start a new launch generation'
sleep 1; sync_now
grep -q '^agents=1$' "$ST/r1.remote-procs" || fail 'the relaunched agent is not running'
pass 'an ended agent reads dead from remote rows and relaunches into the same copy'

# --- cleanup proof --------------------------------------------------------------
proof_refuses() {  # <what> <setup> <undo>
  eval "$2"
  if "$RT" retire r1 prepare > "$T/retire.out" 2>&1; then fail "cleanup did not refuse $1"; fi
  [ -d "$RTASK/wt" ] || fail "cleanup removed the copy despite $1"
  eval "$3"
}
printf 'x\n' > "$RTASK/wt/.gitignore"; git -C "$RTASK/wt" add .gitignore; git -C "$RTASK/wt" commit -q -m ignore; sync_now
proof_refuses 'an ignored file' 'touch "$RTASK/wt/x"' 'rm -f "$RTASK/wt/x"'
grep -q 'dirty:.*x' "$T/retire.out" || fail "the ignored-file refusal did not name it: $(cat "$T/retire.out")"
proof_refuses 'an untracked file' 'touch "$RTASK/wt/new"' 'rm -f "$RTASK/wt/new"'
proof_refuses 'a staged change' 'echo s > "$RTASK/wt/s"; git -C "$RTASK/wt" add s' 'git -C "$RTASK/wt" rm -q --cached s; rm -f "$RTASK/wt/s"'
proof_refuses 'a detached commit' 'git -C "$RTASK/wt" checkout -q --detach; git -C "$RTASK/wt" commit -q --allow-empty -m off' 'git -C "$RTASK/wt" checkout -q fm/r1'
[ -n "$(git -C "$PROJ" rev-parse --verify --quiet refs/firstmate/remote/r1-head)" ] || fail 'the detached commit was not preserved under its custody ref'
proof_refuses 'a stash' 'echo z >> "$RTASK/wt/.gitignore"; git -C "$RTASK/wt" stash -q' 'git -C "$RTASK/wt" stash drop -q'
proof_refuses 'an extra file' 'touch "$RTASK/extra"' 'rm -f "$RTASK/extra"'
hstate | jq -e --arg p "${W#*:}" '.panes[]|select(.pane_id==$p)' >/dev/null || fail 'a refused cleanup closed the worker it refused for'
pass 'cleanup refuses and preserves ignored, untracked, staged, detached, stashed, and extra work, leaving the worker live'

git -C "$RTASK/wt" checkout -q --detach
git -C "$RTASK/wt" commit -q --allow-empty -m abandoned-between-copies
ABANDONED=$(git -C "$RTASK/wt" rev-parse HEAD)
git -C "$RTASK/wt" checkout -q fm/r1
! git -C "$PROJ" cat-file -e "$ABANDONED^{commit}" 2>/dev/null || fail 'the abandoned-commit fixture was already imported'
mkdir -p "$RTASK/channel/scratch"
printf 'verification evidence\000binary\n' > "$RTASK/channel/scratch/.evidence"
cp "$RTASK/channel/scratch/.evidence" "$T/evidence.expected"
"$RT" retire r1 prepare > "$T/retire.out" 2>&1 || fail "cleanup prepare failed on a clean copy: $(cat "$T/retire.out")"
[ "$(git -C "$PROJ" rev-parse "refs/firstmate/remote-history/r1/$ABANDONED")" = "$ABANDONED" ] || fail 'cleanup lost a commit abandoned between courier passes'
ARCHIVE=$(sed -n 's/^artifacts=//p' "$ST/r1.remote-retire")
tar -xOf "$HOMEDIR/data/r1/remote-artifacts/$ARCHIVE.tar" channel/scratch/.evidence > "$T/evidence.actual" || fail 'the saved channel archive omitted scratch evidence'
cmp -s "$T/evidence.expected" "$T/evidence.actual" || fail 'saved channel evidence changed bytes'
printf new >> "$RTASK/channel/scratch/.evidence"
if "$RT" retire r1 remove >/dev/null 2>&1; then fail 'cleanup removed an artifact changed after preservation'; fi
[ -d "$RTASK/wt" ] || fail 'artifact proof refusal removed the worktree'
cp "$T/evidence.expected" "$RTASK/channel/scratch/.evidence"
"$RT" retire r1 prepare > "$T/retire.out" 2>&1 || fail "cleanup could not refresh artifact custody: $(cat "$T/retire.out")"

python3 - "$RTASK/channel/status" <<'PYDATA'
import sys
with open(sys.argv[1], 'a') as stream:
    for i in range(3000):
        stream.write(f'working [at=8]: proof backlog {i}\n')
    stream.write('done [at=8]: status after proof\n')
PYDATA
if "$RT" retire r1 remove > "$T/remove.out" 2>&1; then fail 'removal discarded an undelivered complete status line'; fi
grep -q 'status-not-delivered' "$T/remove.out" || fail 'the removal proof did not check the status boundary'
[ -d "$RTASK/wt" ] || fail 'the status proof refusal removed the remote copy'
"$RT" retire r1 prepare > "$T/retire.out" 2>&1 || fail "cleanup could not finish the new status line: $(cat "$T/retire.out")"
grep -q 'status after proof' "$ST/r1.status" || fail 'cleanup did not import the new complete status line'
grep -q '^phase=proven' "$ST/r1.remote-retire" || fail 'the proven phase was not recorded'
sed -i.bak 's/^phase=.*/phase=removing/' "$ST/r1.remote-retire"
git -C "$REMOTE_HOME/firstmate-remote/repos/proj.git" worktree remove "$RTASK/wt"
IMPORTED=$(sed -n 's/^last_imported=//p' "$ST/r1.remote")
git -C "$REMOTE_HOME/firstmate-remote/repos/proj.git" update-ref refs/heads/fm/r1 "$ABANDONED"
if "$RT" retire r1 remove >/dev/null 2>&1; then fail 'removal retry deleted a changed remote branch'; fi
[ -d "$RTASK" ] || fail 'changed-branch refusal removed remaining artifacts'
git -C "$REMOTE_HOME/firstmate-remote/repos/proj.git" update-ref refs/heads/fm/r1 "$IMPORTED"
"$RT" retire r1 remove > "$T/remove.out" 2>&1 || fail "remote removal did not resume after worktree deletion: $(cat "$T/remove.out")"
[ ! -e "$RTASK" ] || fail 'the remote task folder survived removal'
! git -C "$REMOTE_HOME/firstmate-remote/repos/proj.git" rev-parse --verify --quiet refs/heads/fm/r1 >/dev/null || fail 'the cache branch survived removal'
fm_remote_set() { sed -i.bak "s/^phase=.*/phase=$1/" "$ST/r1.remote-retire"; }
fm_remote_set removing
"$RT" retire r1 remove >/dev/null 2>&1 || fail 'a removal interrupted after the remote delete did not finish on rerun'
grep -q '^phase=removed' "$ST/r1.remote-retire" || fail 'the rerun did not record removed'
pass 'proven cleanup removes both remote ends and a rerun after removal finishes'

# --- lost create response ----------------------------------------------------
"$ROOT/bin/fm-brief.sh" r2 proj --mode local-only --machine pegasus >/dev/null
sed -i.bak 's/{TASK}/two/; s/{FIRSTMATE_SPEC}/two/' "$HOMEDIR/data/r2/brief.md"
touch "$HERDR_DB/lose-create"
OUT=$("$ROOT/bin/fm-spawn.sh" r2 "$PROJ" --machine pegasus --mode local-only --yolo off 2>&1) || fail "lost workspace response was not adopted: $OUT"
rm -f "$HERDR_DB/lose-create"
[ -e "$ST/r2.meta" ] || fail 'adopted initial workspace did not publish a task record'
[ "$(hstate | jq '[.ws[]|select(.label=="firstmate")]|length')" = 1 ] || fail 'workspace recovery duplicated the workspace'
[ "$(cat "$ST/.remote-workspace-$MID")" = "$(hstate | jq -r '.ws[]|select(.label=="firstmate")|.workspace_id')" ] || fail 'workspace recovery did not record custody'
for id in r3 r4; do
  "$ROOT/bin/fm-brief.sh" $id proj --mode local-only --machine pegasus >/dev/null
  sed -i.bak 's/{TASK}/x/; s/{FIRSTMATE_SPEC}/x/' "$HOMEDIR/data/$id/brief.md"
done
touch "$HERDR_DB/lose-create"
OUT=$("$ROOT/bin/fm-spawn.sh" r3 "$PROJ" --machine pegasus --mode local-only --yolo off 2>&1) || fail "a lost tab create did not adopt its one token match: $OUT"
[ "$(grep -c "^tab create" "$HERDR_DB/log")" -ge 1 ] && [ -f "$ST/r3.meta" ] || fail 'the adopted tab was not recorded'
touch "$HERDR_DB/dup-create"
if "$ROOT/bin/fm-spawn.sh" r4 "$PROJ" --machine pegasus --mode local-only --yolo off >/dev/null 2>&1; then fail 'a lost create with two token matches was adopted'; fi
[ ! -e "$ST/r4.meta" ] || fail 'a refused duplicate create published a record'
rm -f "$HERDR_DB/lose-create" "$HERDR_DB/dup-create"
pass 'lost workspace and tab responses adopt exactly one token match and refuse duplicates'

# --- publication gates -------------------------------------------------------
cat > "$STUBS/gh" <<'SH'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_HERDR_DB/gh.log"
case "$1 $2" in
  "pr list") cat "$FAKE_HERDR_DB/gh.prs" 2>/dev/null; exit 0 ;;
  "pr create") echo "https://github.com/acme/proj/pull/7" > "$FAKE_HERDR_DB/gh.prs"; [ ! -e "$FAKE_HERDR_DB/gh.lose" ] || exit 1; echo "https://github.com/acme/proj/pull/7" ;;
  "pr view") echo "$(cat "$FAKE_HERDR_DB/gh.head") $(cat "$FAKE_HERDR_DB/gh.draft" 2>/dev/null || echo false) main OPEN" ;;
esac
SH
chmod +x "$STUBS/gh"
ORIGIN="$T/origin.git"; git clone -q --bare "$PROJ" "$ORIGIN"
git -C "$ORIGIN" remote set-url origin https://github.com/acme/proj
PROJ2="$T/pproj"; git clone -q "$ORIGIN" "$PROJ2"
git -C "$PROJ2" remote set-url origin https://github.com/acme/proj
git -C "$PROJ2" config url."$ORIGIN".insteadOf https://github.com/acme/proj
"$ROOT/bin/fm-brief.sh" p1 pproj --mode direct-PR --machine pegasus >/dev/null
sed -i.bak 's/{TASK}/pub/; s/{FIRSTMATE_SPEC}/pub/' "$HOMEDIR/data/p1/brief.md"
grep -q 'publication requested' "$HOMEDIR/data/p1/brief.md" || fail 'the direct-PR remote brief lacks the publication request'
"$ROOT/bin/fm-spawn.sh" p1 "$PROJ2" --machine pegasus --mode direct-PR --yolo off >/dev/null 2>&1 || fail 'direct-PR remote spawn failed'
PT="$REMOTE_HOME/firstmate-remote/tasks/p1"
git -C "$PT/wt" commit -q --allow-empty -m feature; PSHA=$(git -C "$PT/wt" rev-parse HEAD)
mkdir -p "$PT/channel/publish"; printf 'Add feature\n\nBody.\n' > "$PT/channel/publish/$PSHA.md"
printf 'paused [at=5] [key=publish-%s]: publication requested for %s\n' "${PSHA:0:12}" "$PSHA" >> "$PT/channel/status"
sync_now
[ -f "$HOMEDIR/data/p1/publish/$PSHA.md" ] || fail 'the PR text was not imported'
if "$RT" publish p1 0000000000000000000000000000000000000000 >/dev/null 2>&1; then fail 'publish accepted a commit that is not the imported head'; fi
echo "$PSHA" > "$HERDR_DB/gh.head"; touch "$HERDR_DB/gh.lose"
"$RT" publish p1 "$PSHA" > "$T/pub.out" 2>&1 || fail "publish failed: $(cat "$T/pub.out")"
[ "$(grep -c '^pr create' "$HERDR_DB/gh.log")" = 1 ] || fail 'a lost PR create opened a second PR'
grep -q -- '--repo acme/proj --head fm/p1 --base main' "$HERDR_DB/gh.log" || fail "publish did not pass explicit --repo, --head, and --base: $(cat "$HERDR_DB/gh.log")"
[ "$(git -C "$ORIGIN" rev-parse refs/heads/fm/p1)" = "$PSHA" ] || fail 'publish did not push exactly the verified commit'
grep -q "^done \[at=[0-9]*\]: PR https://github.com/acme/proj/pull/7$" "$ST/p1.status" || fail 'publish did not record the done line'
for point in after-journal after-append after-receipt; do
  printf 'working [at=6]: publication recovery %s\n' "$point" >> "$PT/channel/status"
  FM_REMOTE_TEST_CRASH=$point "$RT" sync pegasus >/dev/null 2>&1
  for l in "$ST"/*.lock "$ST"/.*.lock; do [ -e "$l" ] && rm -rf "$l"; done
  "$RT" publish p1 "$PSHA" > "$T/pub.out" 2>&1 || fail "publication could not recover $point: $(cat "$T/pub.out")"
  [ ! -e "$ST/p1.remote-journal" ] && [ ! -e "$ST/p1.remote-journal.bytes" ] || fail "publication left its $point journal pending"
  python3 - "$ST/p1.status" "$point" <<'PYORDER' || fail 'publication overtook or duplicated imported status'
import sys
lines = open(sys.argv[1]).read().splitlines()
worker = [i for i, line in enumerate(lines) if line == f'working [at=6]: publication recovery {sys.argv[2]}']
completed = [i for i, line in enumerate(lines) if line.startswith('done ') and 'PR https://github.com/acme/proj/pull/7' in line]
assert len(worker) == 1 and completed and worker[0] < completed[-1]
PYORDER
  sync_now
  [ "$(grep -c "publication recovery $point" "$ST/p1.status")" = 1 ] || fail 'courier replayed a journal recovered by publication'
done
pass 'publication recovers each interrupted import before recording its local events'
echo true > "$HERDR_DB/gh.draft"
if "$RT" publish p1 "$PSHA" >/dev/null 2>&1; then fail 'publish accepted a draft PR'; fi
pass 'publication pushes only the verified commit, finds a lost PR, and refuses drafts and mismatches'

SELF_ROOT=$(git -C "$ROOT" rev-list --max-parents=0 HEAD | head -n1)
git -C "$PROJ2" fetch -q "$ROOT" "$SELF_ROOT" || fail 'could not construct self-repository lineage'
"$ROOT/bin/fm-brief.sh" self1 pproj --mode direct-PR --machine pegasus >/dev/null
sed -i.bak 's/{TASK}/self/; s/{FIRSTMATE_SPEC}/self/' "$HOMEDIR/data/self1/brief.md"
OUT=$("$ROOT/bin/fm-spawn.sh" self1 "$PROJ2" --machine pegasus --mode direct-PR --yolo off 2>&1) && fail 'remote dispatch bypassed self-publication authority'
case "$OUT" in *'no publication authority'*) ;; *) fail "dispatch did not identify the missing authority: $OUT" ;; esac
[ ! -e "$ST/self1.remote" ] || fail 'unauthorized dispatch provisioned a remote worker'
BEFORE=$(cat "$HERDR_DB/gh.log")
OUT=$("$RT" publish p1 "$PSHA" 2>&1) && fail 'remote publication bypassed self-publication authority'
case "$OUT" in *'no publication authority'*) ;; *) fail "publication did not identify the missing authority: $OUT" ;; esac
[ "$(cat "$HERDR_DB/gh.log")" = "$BEFORE" ] || fail 'unauthorized publication called GitHub'
printf 'maintainer github.com/acme/proj\n' > "$HOMEDIR/config/firstmate-role"
echo false > "$HERDR_DB/gh.draft"
"$RT" publish p1 "$PSHA" > "$T/pub.out" 2>&1 || fail "authorized self-publication was refused: $(cat "$T/pub.out")"
pass 'remote dispatch and publication require the existing explicit self-publication authority'
for route in upstream gh-default pushurl multiple-pushurls; do
  case "$route" in
    upstream)
      git -C "$PROJ2" remote add upstream https://github.com/acme/upstream
      printf 'maintainer github.com/acme/upstream\n' > "$HOMEDIR/config/firstmate-role" ;;
    gh-default)
      git -C "$PROJ2" config remote.origin.gh-resolved acme/upstream
      printf 'maintainer github.com/acme/upstream\n' > "$HOMEDIR/config/firstmate-role"
      printf 'maintainer github.com/acme/upstream\n' > "$HOMEDIR/config/firstmate-role" ;;
    pushurl) git -C "$PROJ2" remote set-url --push origin https://github.com/acme/elsewhere ;;
    multiple-pushurls)
      git -C "$PROJ2" remote set-url --add --push origin https://github.com/acme/proj
      git -C "$PROJ2" remote set-url --add --push origin https://github.com/acme/elsewhere ;;
  esac
  BEFORE=$(cat "$HERDR_DB/gh.log")
  if "$ROOT/bin/fm-spawn.sh" self1 "$PROJ2" --machine pegasus --mode direct-PR --yolo off > "$T/route.out" 2>&1; then fail "dispatch accepted mismatched $route destinations"; fi
  if "$RT" publish p1 "$PSHA" > "$T/route.out" 2>&1; then fail "publication accepted mismatched $route destinations"; fi
  case "$(cat "$T/route.out")" in *'differs from'*|*'exactly one origin'*) ;; *) fail "destination mismatch was not explicit for $route: $(cat "$T/route.out")" ;; esac
  [ ! -e "$ST/self1.remote" ] || fail "mismatched $route dispatch provisioned a worker"
  [ "$(cat "$HERDR_DB/gh.log")" = "$BEFORE" ] || fail "mismatched $route publication reached GitHub"
  [ "$(git -C "$ORIGIN" rev-parse refs/heads/fm/p1)" = "$PSHA" ] || fail "mismatched $route publication moved the branch"
  case "$route" in
    upstream) git -C "$PROJ2" remote remove upstream ;;
    gh-default) git -C "$PROJ2" config --unset remote.origin.gh-resolved ;;
    pushurl|multiple-pushurls) git -C "$PROJ2" config --unset-all remote.origin.pushurl ;;
  esac
  printf 'maintainer github.com/acme/proj\n' > "$HOMEDIR/config/firstmate-role"
done
"$RT" publish p1 "$PSHA" > "$T/pub.out" 2>&1 || fail "matching publication destinations were refused: $(cat "$T/pub.out")"
pass 'dispatch and publication reject authority, GitHub, and Git push destination mismatches'


R3_TASK="$REMOTE_HOME/firstmate-remote/tasks/r3"
python3 - "$R3_TASK/channel/status" <<'PYDATA'
import sys
with open(sys.argv[1], 'a') as stream:
    for i in range(12000):
        stream.write(f'working [at=9]: backlog event {i}\n')
    stream.write('done [at=10]: backlog final\npartial tail')
PYDATA
if "$RT" retire r3 prepare > "$T/retire.out" 2>&1; then fail 'cleanup accepted an incomplete status transfer'; fi
grep -q 'status-not-delivered' "$T/retire.out" || fail 'backlog refusal did not identify undelivered status'
[ -d "$R3_TASK/wt" ] || fail 'backlog refusal removed the remote copy'
R3_WINDOW=$(sed -n 's/^window=//p' "$ST/r3.meta")
hstate | jq -e --arg p "${R3_WINDOW#*:}" '.panes[] | select(.pane_id==$p)' >/dev/null || fail 'incomplete status delivery closed the worker'
for i in $(seq 1 12); do
  sync_now
  grep -q 'backlog final' "$ST/r3.status" && break
done
[ "$(grep -c 'backlog event' "$ST/r3.status")" = 12000 ] || fail 'courier backlog delivery lost or repeated status lines'
[ "$(grep -c 'backlog final' "$ST/r3.status")" = 1 ] || fail 'the complete status tail did not reach supervision'
! grep -q 'partial tail' "$ST/r3.status" || fail 'an incomplete status tail became an event'
"$RT" retire r3 prepare > "$T/retire.out" 2>&1 || fail "r3 cleanup preparation failed: $(cat "$T/retire.out")"
pass 'cleanup requires complete status delivery while preserving an incomplete tail as an artifact'

sed -i.bak 's/^phase=.*/phase=removing/' "$ST/r3.remote-retire"
git -C "$REMOTE_HOME/firstmate-remote/repos/proj.git" worktree remove "$REMOTE_HOME/firstmate-remote/tasks/r3/wt"
git -C "$REMOTE_HOME/firstmate-remote/repos/proj.git" update-ref -d refs/heads/fm/r3
"$RT" retire r3 remove > "$T/remove.out" 2>&1 || fail "removal did not resume after branch deletion: $(cat "$T/remove.out")"
[ ! -e "$REMOTE_HOME/firstmate-remote/tasks/r3" ] || fail 'resumed removal left the remote folder'
pass 'removal also resumes when both the worktree and task branch are already absent'
