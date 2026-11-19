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
[ ! -e "$FAKE_REMOTE_HOME/.down" ] || { echo "ssh: connect to host: Operation timed out" >&2; exit 255; }
HOME=$FAKE_REMOTE_HOME PATH=$FAKE_REMOTE_PATH exec bash -c "$*"
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
  "pane read") printf '\n' ;;
  "pane send-text"|"pane send-keys") echo '{"result":{}}' ;;
  *) echo "{\"error\":{\"code\":\"unsupported\",\"message\":\"$*\"}}"; exit 1 ;;
esac
SH
chmod +x "$STUBS/ssh" "$STUBS/herdr" "$REMOTE_STUBS/claude"
export PATH="$STUBS:$PATH" FM_REMOTE_SSH="$STUBS/ssh"

RT="$ROOT/bin/fm-remote-task.sh"
ST="$HOMEDIR/state"
sync_now() { "$RT" sync pegasus >>"$T/sync.log" 2>&1; }
hstate() { cat "$HERDR_DB/state.json"; }

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
jq -e --arg p "$RTASK/wt" '.projects[$p].hasTrustDialogAccepted == true' "$REMOTE_HOME/.claude.json" >/dev/null || fail 'remote Claude trust was not registered'
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

for point in after-journal after-append after-receipt; do
  printf 'working [at=3]: %s\n' "$point" >> "$RTASK/channel/status"
  FM_REMOTE_TEST_CRASH=$point "$RT" sync pegasus >/dev/null 2>&1
  rm -rf "$ST/.remote-sync-$MID.lock" "$ST/.remote-sync-$MID".lock* 2>/dev/null
  for l in "$ST"/*.lock "$ST"/.*.lock; do [ -e "$l" ] && rm -rf "$l"; done
  sync_now
  [ "$(grep -c "working \[at=3\]: $point" "$ST/r1.status")" = 1 ] || fail "a crash $point lost or repeated the line"
done
pass 'a crash at every import step neither loses nor repeats a status line'

cp "$RTASK/channel/status" "$T/status.save"
head -n1 "$T/status.save" > "$RTASK/channel/status"
OFF=$(sed -n 's/^status_offset=//p' "$ST/r1.remote")
sync_now
grep -q 'replaced or shortened' "$ST/r1.remote-alert" || fail 'a shortened remote status log did not raise a continuity alert'
[ "$(sed -n 's/^status_offset=//p' "$ST/r1.remote")" = "$OFF" ] || fail 'the status offset moved after a continuity break'
cp "$T/status.save" "$RTASK/channel/status"; rm -f "$ST/r1.remote-alert"
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
rm -f "$REMOTE_HOME/.down"; touch "$HERDR_DB/down"
sync_now
[ "$(sed -n 's/^state=//p' "$ST/.remote-link-$MID")" = herdr-unavailable ] || fail 'a down remote Herdr did not read herdr-unavailable'
rm -f "$HERDR_DB/down"; sync_now
pass 'an outage reads unknown, keeps the worker state, and refuses cleanup intact'

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

# --- crash and relaunch ------------------------------------------------------
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

"$RT" retire r1 prepare > "$T/retire.out" 2>&1 || fail "cleanup prepare failed on a clean copy: $(cat "$T/retire.out")"
grep -q '^phase=proven' "$ST/r1.remote-retire" || fail 'the proven phase was not recorded'
"$RT" retire r1 remove >/dev/null 2>&1 || fail 'remote removal failed'
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
"$ROOT/bin/fm-spawn.sh" r2 "$PROJ" --machine pegasus --mode local-only --yolo off >/dev/null 2>&1
rm -f "$HERDR_DB/lose-create"
[ ! -e "$ST/r2.meta" ] || fail 'a spawn with a lost workspace response published a record'
OUT=$("$ROOT/bin/fm-spawn.sh" r2 "$PROJ" --machine pegasus --mode local-only --yolo off 2>&1) && fail 'a retry adopted an unrecorded firstmate workspace'
case "$OUT" in *'labeled firstmate'*) ;; *) fail "retry after a lost workspace create did not refuse plainly: $OUT" ;; esac
# The captain removes the orphan; the task then spawns and records its workspace.
ORPHAN=$(hstate | jq -r '.ws[]|select(.label=="firstmate")|.workspace_id')
herdr --machine "$MID" tab close "$ORPHAN:t1" >/dev/null
"$ROOT/bin/fm-spawn.sh" r2 "$PROJ" --machine pegasus --mode local-only --yolo off >/dev/null 2>&1 || fail 'r2 did not spawn after the orphan was removed'
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
pass 'a lost create adopts exactly one token match and refuses an orphan or duplicates'

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
echo true > "$HERDR_DB/gh.draft"
if "$RT" publish p1 "$PSHA" >/dev/null 2>&1; then fail 'publish accepted a draft PR'; fi
pass 'publication pushes only the verified commit, finds a lost PR, and refuses drafts and mismatches'
