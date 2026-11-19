import subprocess,os,pathlib,shlex
r=pathlib.Path.cwd(); d=r/".test-live"; h=d/"guard-home"; ev=pathlib.Path("/home/runkai/.no-mistakes/evidence/01M7RND5YJKT5A6WVSCF8K461C")
e=os.environ.copy()
for k in ["FM_ROOT_OVERRIDE","FM_STATE_OVERRIDE","FM_DATA_OVERRIDE","FM_CONFIG_OVERRIDE","FM_PROJECTS_OVERRIDE","FM_GATE_REFUSE_BYPASS","TASKS_AXI_FILE","TASKS_AXI_BACKEND"]: e.pop(k,None)
e["FM_HOME"]=str(h)
log=open(ev/"live-cli-guards.log","w",buffering=1)
def run(a,success):
 p=subprocess.run(a,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.write("$ "+shlex.join(a)+"\n"+p.stdout+f"exit={p.returncode}\n")
 assert (p.returncode==0)==success,(a,p.returncode,p.stdout)
 return p.stdout
run(["bash","bin/fm-lab-home.sh","create",str(h)],True)
out=run(["bash","bin/fm-spawn.sh","guard1",str(d/"throwaway"),"--machine","not-opted-in","--mode","local-only","--yolo","off"],False)
assert "not configured exactly once" in out
assert not list((h/"state").iterdir())
log.write("Observed: unconfigured machine refused before task records or remote provisioning.\n")
(h/"config/remote-machines").write_text("0123456789abcdef0123456789abcdef loop "+str(d/"remote-data")+"\n")
run(["bash","bin/fm-brief.sh","guard2","throwaway","--mode","local-only","--machine","loop","--herdr-lab"],True)
b=(h/"data/guard2/brief.md").read_text()
assert "Remote machine: loop" in b and "Ship branch: fm/guard2" in b
assert str(d/"remote-data/tasks/guard2/channel/status") in b
(ev/"generated-remote-brief.md").write_text(b)
log.write("Observed: local-only remote brief generated with configured remote channel and fm/guard2 branch.\n")
out=run(["bash","bin/fm-brief.sh","guard3","throwaway","--mode","no-mistakes","--machine","loop","--herdr-lab"],False)
assert not (h/"data/guard3/brief.md").exists()
out=run(["bash","bin/fm-brief.sh","guard4","throwaway","--scout","--machine","loop","--herdr-lab"],False)
assert not (h/"data/guard4/brief.md").exists()
log.write("Observed: unsupported no-mistakes and scout remote briefs refused without generating task briefs.\n")
print(log.name)
