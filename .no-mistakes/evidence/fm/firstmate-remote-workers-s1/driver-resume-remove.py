from common import *
sync()
wr=pilot/'crash-transport'; wr.mkdir(exist_ok=True)
(wr/'ssh').write_text('''#!/usr/bin/env python3
import os,sys,subprocess
if sys.argv[-1]!="/bin/bash -s": os.execv("/usr/bin/ssh",["/usr/bin/ssh"]+sys.argv[1:])
b=sys.stdin.buffer.read()
if b'git -C "$C" worktree remove "$T/wt"' in b:
 b=bytes([10]).join([b'git() { command git "$@"; rc=$?; case "$*" in *"worktree remove"*) exit 97 ;; esac; return "$rc"; }',b])
r=subprocess.run(['/usr/bin/ssh']+sys.argv[1:],input=b)
sys.exit(r.returncode)
'''); (wr/'ssh').chmod(0o700)
r=run(['bin/fm-remote-task.sh','retire','pilot','remove'],{'PATH':str(wr)+':'+env['PATH']},check=False); assert r.returncode!=0 and 'lost its response' in r.stdout
assert fields('pilot.remote-retire')['phase']=='removing'; ssh('test ! -e '+remote+'/wt && test -d '+remote); note('INTERRUPTION INJECTED: actual git worktree remove completed, remote shell exited before branch/folder removal')
run(['bin/fm-remote-task.sh','retire','pilot','remove']); assert fields('pilot.remote-retire')['phase']=='removed'; ssh('test ! -e '+remote); run(['bin/fm-teardown.sh','pilot']); assert not (state/'pilot.meta').exists(); assert not (pilot/'copies/pilot/worktree').exists(); note('RESUME VERIFIED: remaining remote branch and folder removed, local cleanup completed, landing commit retained'); focus()
