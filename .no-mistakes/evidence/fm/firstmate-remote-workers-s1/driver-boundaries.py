from common import *
h=pilot/'boundary-home'; run(['bin/fm-lab-home.sh','create',str(h)])
e={'FM_HOME':str(h)}; repo=pilot/'throwaway'
r=run(['bin/fm-spawn.sh','not-opted-in',str(repo),'--machine','fm-pilot','--mode','local-only','--yolo','off'],e,check=False); assert r.returncode!=0 and ('not opted' in r.stdout or 'remote-machines' in r.stdout)
(h/'config/remote-machines').write_text('966df3cddb5e527a693a675d66d27109 fm-pilot ~/firstmate-remote-pilot\n')
for args in [ ['--mode','no-mistakes'], ['--mode','local-only','--harness','codex'], ['--mode','local-only','--scout'] ]:
 r=run(['bin/fm-spawn.sh','unsupported',str(repo),'--machine','fm-pilot','--yolo','off']+args,e,check=False); assert r.returncode!=0
assert not list((h/'state').glob('*.meta')) and not list((h/'state').glob('*.remote'))
(h/'config/remote-machines').write_text('malformed entry with extra fields extra\n')
r=run(['bin/fm-remote-task.sh','sync','fm-pilot'],e,check=False); assert r.returncode!=0
note('BOUNDARIES VERIFIED: saved Herdr profile alone does not authorize dispatch; unsupported mode/harness/scout and malformed opt-in refuse before provisioning')
