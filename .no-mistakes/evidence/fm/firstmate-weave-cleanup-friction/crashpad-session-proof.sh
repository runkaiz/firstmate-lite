#!/usr/bin/env bash
set -eu
. tests/fixtures.sh
. bin/fm-git-worktree-lib.sh
case_dir="$PWD/.browser-test/repro"
mkdir -p "$case_dir"
fm_test_spawn_home "$case_dir/home" codex
printf 'manual\n' > "$case_dir/home/config/backlog-backend"
fm_git_init_commit "$case_dir/project"
base=$(git -C "$case_dir/project" rev-parse HEAD)
main=$(git -C "$case_dir/project" symbolic-ref --short HEAD)
fm_git_worktree_allocate "$case_dir/home/state" browser-regression "$case_dir/home" "$case_dir/project" "$case_dir/copies" "$base" "refs/heads/$main"
copy=$FM_GIT_WORKTREE_PATH
fm_write_meta "$case_dir/home/state/browser-regression.meta" \
  'window=native-fixture:fm-browser-regression' 'endpoint_task_id=browser-regression' 'backend=tmux' \
  "worktree=$copy" "project=$case_dir/project" 'kind=ship' 'mode=local-only' \
  'spawn_gen=s1792922400.123.456' 'allocator=git'
fakebin=$(fm_fakebin "$case_dir/fake")
printf '#!/usr/bin/env bash\ncase "$1" in list-windows) printf "main\\n" ;; display-message) exit 1 ;; esac\n' > "$fakebin/tmux"
chmod +x "$fakebin/tmux"
export FM_HOME="$case_dir/home" FM_ROOT_OVERRIDE="$PWD" FM_STATE_OVERRIDE="$case_dir/home/state" FM_DATA_OVERRIDE="$case_dir/home/data" FM_CONFIG_OVERRIDE="$case_dir/home/config" FM_TEARDOWN_GUARD_DONE=1
browser() { (cd "$copy" && chrome-devtools-axi "$@"); }
browser open 'data:text/html,<title>cleanup regression</title>'
python3 - "$copy" <<'PYTHON'
import os, subprocess, sys
from pathlib import Path
copy=Path(sys.argv[1]).resolve()
rows=[]
for row in subprocess.check_output(['ps','-eo','pid,ppid,pgid,sid,comm'],text=True).splitlines()[1:]:
    pid=int(row.split()[0])
    try:
        if Path('/proc',str(pid),'cwd').resolve()==copy: rows.append(row)
    except (FileNotFoundError,PermissionError): pass
print('PID PPID PGID SID COMMAND')
print('\n'.join(rows))
for row in rows:
    pid,ppid,pgid,sid,comm=row.split(maxsplit=4)
    if comm.startswith('chrome_crashpad'):
        print('crashpad leaders:',subprocess.run(['ps','-p',pgid+','+sid,'-o','pid,ppid,pgid,sid,comm'],text=True,capture_output=True).stdout.strip())
PYTHON
if out=$(PATH="$fakebin:$PATH" bash bin/fm-teardown.sh browser-regression 2>&1); then
  printf '%s\n' "$out"
  fail 'expected current cleanup failure was not reproduced'
fi
printf '%s\n' "$out"
assert_contains "$out" 'beside other process' 'cleanup did not reach the reported ownership failure'
[ -d "$copy" ] || fail 'refusal removed copy'
browser stop
out=$(PATH="$fakebin:$PATH" bash bin/fm-teardown.sh browser-regression 2>&1)
printf '%s\n' "$out"
[ ! -e "$copy" ] || fail 'manual stop did not release copy'
pass 'reported crashpad refusal reproduced; manual stop allows teardown'
