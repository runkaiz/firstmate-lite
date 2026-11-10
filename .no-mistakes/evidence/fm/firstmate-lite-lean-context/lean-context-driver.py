import os, json, subprocess, time, hashlib, shutil
from pathlib import Path
ROOT=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73DHBJNPJH59DCDGS0CRYD5')
WORK=ROOT/'.test-lean-context'
EVID=Path('/home/runkai/.no-mistakes/evidence/01M73DHBJNPJH59DCDGS0CRYD5')
EVID.mkdir(parents=True,exist_ok=True)
env=dict(os.environ)
for key in list(env):
 if (key.startswith('FM_') and key.endswith('_OVERRIDE')) or key in ['CLAUDECODE','PI_CODING_AGENT','GROK_AGENT','FM_PI_HARNESS','CLAUDE_CONFIG_DIR','CODEX_HOME','NM_HOME']:
  env.pop(key,None)
user=WORK/'user'
env.update(HOME=str(user),XDG_CONFIG_HOME=str(user/'.config'),XDG_DATA_HOME=str(user/'.local/share'),XDG_STATE_HOME=str(user/'.local/state'),CODEX_HOME=str(user/'.codex'),NM_HOME=str(user/'.no-mistakes'),GH_CONFIG_DIR=str(user/'.config/gh'),FM_SESSION_START_TIMEOUT='45',FM_STARTUP_NETWORK_TIMEOUT='15',PYTHONDONTWRITEBYTECODE='1',TMPDIR=str(WORK))
lab=ROOT/'.test-lean-context/lab'
env['FM_HOME']=str(lab)
results=[]
def run(name,args,extra=None):
 e=dict(env); e.update(extra or {})
 r=subprocess.run(args,env=e,cwd=ROOT,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=65)
 (EVID/(name+'.log')).write_text('$ '+' '.join(args)+'\n'+r.stdout+'\nexit: '+str(r.returncode)+'\n')
 if r.returncode: raise AssertionError((name,r.returncode,r.stdout))
 return r.stdout
def check(name,ok,detail):
 results.append(dict(name=name,pass_=bool(ok),detail=detail))
 print(name, 'PASS' if ok else 'FAIL', detail, flush=True)
 if not ok: raise AssertionError(name)
def wait_network():
 run('network-wait',['bash','bin/fm-startup-network.sh','wait','20'])
# Compare the same public startup interface with unchanged dependencies and home.
base=ROOT/'.test-lean-context/baseline/bin/fm-session-start.sh'
old=run('baseline-startup',['bash',str(base)])
wait_network()
new=run('lean-startup',['bash','bin/fm-session-start.sh'])
wait_network()
status=run('usage-status',['python3','bin/fm-usage-auto.py','status'])
usage=json.loads(status)
check('quiet startup retains automatic usage collection','LOCAL USAGE' in old and 'LOCAL USAGE' not in new and usage.get('observed_at') and (lab/'data/usage-ledger/usage.sqlite').exists(),f'baseline digest {len(old.encode())} bytes; new digest {len(new.encode())} bytes; usage enabled={usage.get("enabled")}, coverage={usage.get("coverage")}')
old_agents=subprocess.check_output(['git','show','57351c89c552aab5257e1333e717626ddf247dea:AGENTS.md'],cwd=ROOT)
new_agents=(ROOT/'AGENTS.md').read_bytes()
check('always-loaded instruction bulk reduced by a third to a half',1/3 <= 1-len(new_agents)/len(old_agents) <= 1/2,f'AGENTS.md {len(old_agents)} -> {len(new_agents)} bytes ({100*(1-len(new_agents)/len(old_agents)):.1f}% reduction); size measurement only, not an instruction-behavior assertion')
# Real durable wake API, not a fake toolchain.
run('enqueue',['bash','-c','. bin/fm-wake-lib.sh; fm_wake_append check lean-context "review: lean context event remains actionable"'])
(lab/'config/crew-dispatch.json').write_text('{invalid json')
before=(lab/'data/usage-ledger/status.json').read_bytes()
reemit=run('reemit',['bash','bin/fm-session-start.sh','--reemit'])
check('re-emission retains actions and does not refresh accounting','CONTEXT RE-EMIT' in reemit and 'lean context event remains actionable' in reemit and 'WAKE_ACK_REQUIRED' in reemit and 'CREW_DISPATCH: invalid' in reemit and before==(lab/'data/usage-ledger/status.json').read_bytes(), 'Emitted durable wake, acknowledgement requirement, invalid dispatch diagnostic; usage status stayed byte-identical')
wait_network()
report=run('network-report',['bash','bin/fm-startup-network.sh','report'])
check('deferred credential diagnostic survives lean output','NEEDS_GH_AUTH' in reemit or 'NEEDS_GH_AUTH' in report,'Isolated empty GH_CONFIG_DIR yields real NEEDS_GH_AUTH, available in digest or deferred report')
(lab/'config/crew-dispatch.json').unlink()
# End-user preexisting away and quiet records; no supervision daemon starts.
for mode in ['away','quiet']:
 (lab/'state/.afk').write_text(mode+'\n'+str(int(time.time()))+'\n')
 text=run(mode+'-startup',['bash','bin/fm-session-start.sh','--reemit'])
 check(mode+' restart keeps the correct supervision owner', ('load /'+('afk' if mode=='away' else 'quiet')) in text and ('Away mode is active' if mode=='away' else 'Quiet mode is active') in text and 'daemon owns' in text and (mode!='quiet' or '/quiet off' in text), 'Actual startup emits mode-specific delegation and closing guidance')
 wait_network()
(lab/'state/.afk').unlink()
# Force a real lock-publication failure; snapshot verifies no fleet mutation.
def snapshot():
 return {str(p.relative_to(lab)):hashlib.sha256(p.read_bytes()).hexdigest() for p in lab.rglob('*') if p.is_file()}
before=snapshot()
state=lab/'state'
state.chmod(0o500)
try:
 readonly=run('read-only-startup',['bash','bin/fm-session-start.sh'])
finally:
 state.chmod(0o755)
after=snapshot()
check('unwritable lock refuses mutation and keeps queued actions','READ-ONLY SESSION' in readonly and 'cannot write session lock' in readonly and 'Stay read-only: do not arm' in readonly and 'skipped (read-only session)' in readonly and before==after, f'All {len(before)} lab files byte-identical after read-only startup')
# The changed Claude document is consumed by the real public prompt renderer.
(lab/'config/supervision-host-off').touch()
claude=run('claude-supervision',['bash','bin/fm-supervision-instructions.sh','--harness','claude'])
check('Claude startup renderer preserves hook ownership','Stop `asyncRewake` hook' in claude and 'do not run `bin/fm-watch-arm.sh`' in claude and 'WAKE_ACK_REQUIRED' in claude and 'turn-end guard' in claude and 'Mode: Claude Stop-hook-owned supervision.' in claude,'Generated instruction interface includes Stop ownership, drain/ack, no manual rearm, and guard reference; no model interpretation claim')
(EVID/'lean-context-results.json').write_text(json.dumps(results,indent=2)+'\n')

