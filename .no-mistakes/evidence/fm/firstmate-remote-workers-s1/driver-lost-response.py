from common import *
import shutil
repo=pilot/'throwaway'; task='pilot-retry'; run(['bin/fm-brief.sh',task,str(repo),'--mode','local-only','--machine','fm-pilot','--herdr-lab'])
b=lab/'data'/task/'brief.md'; b.write_text(b.read_text().replace('{TASK}','This is a disposable launch recovery check. Do not edit repository files. Append done status saying ready in branch fm/pilot-retry at the current HEAD. Remain available.').replace('{FIRSTMATE_SPEC}','Make no commits and run no Herdr commands. Only read the brief, inspect HEAD and append the completion status to its specified channel.'))
wr=pilot/'lost-response'; wr.mkdir(); real=shutil.which('herdr'); assert real
(wr/'herdr').write_text('#!/usr/bin/env python3\nimport sys,subprocess,pathlib\nr=subprocess.run('+repr([real])+'+sys.argv[1:],stdout=subprocess.PIPE)\nif ("workspace" in sys.argv or "tab" in sys.argv) and "create" in sys.argv and r.returncode==0:\n pathlib.Path('+repr(str(pilot/'response-dropped'))+').touch()\n sys.exit(1)\nsys.stdout.buffer.write(r.stdout)\nsys.exit(r.returncode)\n'); (wr/'herdr').chmod(0o700)
focus(); r=run(['bin/fm-spawn.sh',task,str(repo),'--machine','fm-pilot','--mode','local-only','--yolo','off'],{'PATH':str(wr)+':'+env['PATH']}); assert (pilot/'response-dropped').exists()
m=fields(task+'.meta'); rec=fields(task+'.remote'); assert m['window'].startswith(m['machine_id']+':')
w=json.loads(run(['herdr','--machine','fm-pilot','workspace','list']).stdout)['result']['workspaces']; own=[x for x in w if x['label']=='firstmate']; assert len(own)==1
t=json.loads(run(['herdr','--machine','fm-pilot','tab','list','--workspace',own[0]['workspace_id']]).stdout)['result']['tabs']; assert len(t)==1 and t[0]['label']=='fm-'+task+'.'+rec['token']; focus()
for i in range(15):
 sync()
 if (state/(task+'.status')).exists() and 'done' in (state/(task+'.status')).read_text(): break
 time.sleep(2)
run(['bin/fm-peek.sh',task,'25']); assert 'done' in (state/(task+'.status')).read_text(); note('LOST RESPONSE VERIFIED: real Herdr creation succeeded, transport dropped its response, launch token adopted exactly one tab without duplication or focus change')
run(['bin/fm-teardown.sh',task]); assert not (state/(task+'.meta')).exists(); focus()
