import os, pathlib, subprocess, socket, time, json, shlex
root=pathlib.Path.cwd(); d=root/".test-live"; ev=pathlib.Path("/home/runkai/.no-mistakes/evidence/01M7RND5YJKT5A6WVSCF8K461C")
h=d/"remote-home"; (h/".config/herdr").mkdir(parents=True,exist_ok=True)
env=os.environ.copy(); env.update(HOME=str(h),XDG_CONFIG_HOME=".test-live/xdg",XDG_DATA_HOME=str(d/"xdg-data"),XDG_STATE_HOME=str(d/"xdg-state"),XDG_CACHE_HOME=str(d/"xdg-cache"),TMPDIR=str(d/"tmp"),FM_HERDR_LAB_STATE_DIR=str(d/"lab-state"))
for k in ["HERDR_SOCKET_PATH","HERDR_SESSION","HERDR_PANE_ID","HERDR_WORKSPACE_ID","HERDR_TAB_ID","FM_ROOT_OVERRIDE","FM_STATE_OVERRIDE","FM_DATA_OVERRIDE","FM_CONFIG_OVERRIDE","FM_PROJECTS_OVERRIDE"]: env.pop(k,None)
log=open(ev/"live-setup.log","w",buffering=1)
def run(a,check=True):
 p=subprocess.run(a,env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT); print("$ "+shlex.join(map(str,a))+"\n"+p.stdout,file=log); print(p.stdout,flush=True)
 if check and p.returncode: raise RuntimeError(f"exit {p.returncode}: {a}")
 return p
lab="fm-lab-rw-gate"
# The helper owns preparation and starts only the named lab server.
run(["bin/fm-herdr-lab.sh","provision",lab])
try:
 run(["bin/fm-herdr-lab.sh","run",lab,"workspace","create","--label","lab-observer","--cwd",str(root),"--no-focus"])
 
 if not (d/"host-key").exists(): run(["ssh-keygen","-q","-t","ed25519","-N","","-f",str(d/"host-key")])
 
 if not (d/"client-key").exists(): run(["ssh-keygen","-q","-t","ed25519","-N","","-f",str(d/"client-key")])
 (d/"authorized_keys").write_text((d/"client-key.pub").read_text()); (d/"authorized_keys").chmod(0o600)
 s=socket.socket(); s.bind(("127.0.0.1",0)); port=s.getsockname()[1]; s.close()
 # The command bridge only adds isolation and routes Herdr through the lab helper.
 remote=d/"remote-command"
 remote.write_text("#!/bin/bash\ncd "+shlex.quote(str(root))+" || exit 1\nexport HOME="+shlex.quote(str(h))+" XDG_CONFIG_HOME=.test-live/xdg FM_HERDR_LAB_STATE_DIR="+shlex.quote(str(d/"lab-state"))+"\nexport GIT_AUTHOR_NAME=fmtest GIT_AUTHOR_EMAIL=test@example.invalid GIT_COMMITTER_NAME=fmtest GIT_COMMITTER_EMAIL=test@example.invalid\nexport PATH="+shlex.quote(str(d/"remote-bin"))+":$PATH\nexec /bin/bash -c \"$SSH_ORIGINAL_COMMAND\"\n")
 remote.chmod(0o700)
 (d/"remote-bin").mkdir(exist_ok=True)
 bridge=d/"remote-bin/herdr"
 bridge.write_text("#!/usr/bin/python3\nimport os,sys,subprocess\nos.environ[\"PATH\"]=\"/home/runkai/.local/bin:/usr/bin:/bin\"\na=sys.argv[1:]; session=None\nif a in [[\"--version\"],[\"-V\"]]: os.execv(\"/home/runkai/.local/bin/herdr\",[\"herdr\"]+a)\nif \"--session\" in a:\n i=a.index(\"--session\"); session=a[i+1]; del a[i:i+2]\nif session and session != \"fm-lab-rw-gate\": sys.exit(91)\nos.execv(\""+str(root/"bin/fm-herdr-lab.sh")+"\",[\"fm-herdr-lab.sh\",\"run\",\"fm-lab-rw-gate\"]+a)\n")
 bridge.chmod(0o700)
 (d/"sshd_config").write_text(f"Port {port}\nListenAddress 127.0.0.1\nHostKey {d}/host-key\nPidFile {d}/sshd.pid\nAuthorizedKeysFile {d}/authorized_keys\nStrictModes no\nPasswordAuthentication no\nKbdInteractiveAuthentication no\nUsePAM no\nAllowUsers runkai\nForceCommand {remote}\nLogLevel VERBOSE\n")
 daemon=subprocess.Popen(["/usr/bin/sshd","-D","-e","-f",str(d/"sshd_config")],stdout=open(d/"sshd.log","w"),stderr=subprocess.STDOUT)
 try:
  time.sleep(.5)
  if daemon.poll() is not None: raise RuntimeError((d/"sshd.log").read_text())
  (d/"ssh-config").write_text(f"Host fm-lab-loop\n HostName 127.0.0.1\n Port {port}\n User runkai\n IdentityFile {d}/client-key\n IdentitiesOnly yes\n UserKnownHostsFile {d}/known_hosts\n StrictHostKeyChecking accept-new\n")
  (d/"local-bin").mkdir(exist_ok=True)
  (d/"ssh").mkdir(exist_ok=True)
  (d/"ssh/config").write_text((d/"ssh-config").read_text())
  hw=d/"local-bin/herdr"
  hw.write_text("#!/bin/bash\nexec /usr/bin/bwrap --ro-bind / / --bind "+shlex.quote(str(root))+" "+shlex.quote(str(root))+" --bind "+shlex.quote(str(d/"ssh"))+" /home/runkai/.ssh --bind /var/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7RND5YJKT5A6WVSCF8K461C/.test-live/tmp /tmp --dev /dev --proc /proc -- /home/runkai/.local/bin/herdr \"$@\"\n")
  hw.chmod(0o700)
  sw=d/"local-bin/ssh"; sw.write_text("#!/bin/bash\n[ ! -e "+shlex.quote(str(d/"down"))+" ] || exit 255\nexec /usr/bin/ssh -F "+shlex.quote(str(d/"ssh-config"))+" \"$@\"\n"); sw.chmod(0o700)
  env["PATH"]=str(d/"local-bin")+":"+env["PATH"]
  run([str(sw),"fm-lab-loop","printf live-ssh-ok"])
  run(["herdr","machine","add","fm-lab-loop","--label","loop","--remote-session",lab])
  profiles=run(["herdr","machine","list","--json"]).stdout
  (d/"profiles.json").write_text(profiles)
  run(["herdr","--machine","loop","workspace","list"])
  (d/"setup-ready").touch()
  while not (d/"finish").exists(): time.sleep(.2)
 finally:
  daemon.terminate(); daemon.wait()
finally:
 run(["bin/fm-herdr-lab.sh","teardown",lab],False)
