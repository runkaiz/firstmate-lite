from common import *
import tarfile,io
focus(); sync()
# Faults contain only disposable pilot data, which is saved in the evidence.
ssh("printf 'ignored.txt\\n' >> /Users/runkai/firstmate-remote-pilot/repos/throwaway.git/info/exclude; printf 'unique ignored pilot data\\n' > "+remote+'/wt/ignored.txt')
r=run(['bin/fm-remote-task.sh','retire','pilot','prepare'],check=False); assert r.returncode and 'worker left running' in r.stdout and 'ignored.txt' in r.stdout
ssh('test -d '+remote+'/wt; test -f '+remote+'/wt/ignored.txt'); procs=fields('pilot.remote-procs'); assert int(procs['agents'])>=1
saved=ssh('cat '+remote+'/wt/ignored.txt').stdout; (ev/'preserved-ignored.txt').write_text(saved); ssh('rm '+remote+'/wt/ignored.txt')
ssh('git -C '+remote+'/wt checkout --detach -q; git -C '+remote+'/wt -c user.name=Pilot -c user.email=pilot@example.invalid -c commit.gpgsign=false commit --allow-empty -q -m detached-pilot-proof')
det=ssh('git -C '+remote+'/wt rev-parse HEAD').stdout.strip(); r=run(['bin/fm-remote-task.sh','retire','pilot','prepare'],check=False); assert r.returncode and 'head-not-on-branch:detached' in r.stdout and 'worker left running' in r.stdout
ssh("git -C "+remote+"/wt checkout -q fm/pilot; mkdir -p "+remote+"/channel/scratch; printf 'unique channel artifact\n' > "+remote+"/channel/scratch/proof.txt")
sync(); note('PRESERVATION GUARDS VERIFIED: ignored unique file and detached HEAD refuse before closing the real Claude worker')
run(['bin/fm-send.sh','pilot','The pilot is complete. Do not change files further. Append done status saying ready in branch fm/pilot at the current commit. Remain available without running tools after that.'])
for i in range(12):
 sync()
 s=(state/'pilot.status').read_text()
 if any(x.startswith('done ') or x.startswith('done:') for x in s.splitlines()): break
 time.sleep(2)
assert any(x.startswith('done ') or x.startswith('done:') for x in s.splitlines()), 'worker never declared completion'
focus(); run(['bin/fm-merge-local.sh','pilot']); run(['git','-C',str(pilot/'throwaway'),'log','-2','--oneline']); assert (pilot/'throwaway/hello.txt').read_text()=='remote pilot\n'
run(['bin/fm-remote-task.sh','retire','pilot','prepare'])
proof=fields('pilot.remote-retire'); assert proof['phase']=='proven'; archive=lab/'data/pilot/remote-artifacts'/(proof['artifacts']+'.tar'); assert hashlib.sha256(archive.read_bytes()).hexdigest()==proof['artifacts']
with tarfile.open(archive) as tf:
 assert tf.extractfile('channel/scratch/proof.txt').read()==b'unique channel artifact\n'
 (ev/'channel-artifact-proof.txt').write_bytes(tf.extractfile('channel/scratch/proof.txt').read())
run(['git','-C',str(pilot/'throwaway'),'cat-file','-t',det]); assert run(['git','-C',str(pilot/'throwaway'),'rev-parse','refs/firstmate/remote-history/pilot/'+det]).stdout.strip()==det
note('PRESERVATION VERIFIED: detached commit remains in local custody ref; scratch bytes match custody archive; every complete status delivered before proof')
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
