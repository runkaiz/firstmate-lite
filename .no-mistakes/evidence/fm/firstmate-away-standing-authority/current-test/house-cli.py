import pathlib, subprocess, os
root=pathlib.Path.cwd()
lab=root/'.v/edges'
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E4EMMHJV5XTAZSM4MWEZTN/current-test')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND')}
env['FM_HOME']=str(lab)
log=[]
def call(name,*args,actor='main',expected=0):
 p=subprocess.run([str(root/'bin'/name),*args],env=dict(env,FM_SUPERVISION_ACTOR=actor),text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT)
 log.append('$ '+name+' '+' '.join(args)+' [actor='+actor+']\n'+p.stdout+'exit='+str(p.returncode)+'\n')
 assert p.returncode==expected, log[-1]
 return p.stdout
try:
 rule=' '.join(f'Before granting request {i}, check CPU, memory, disk and active suite ownership;' for i in range(80))+' grant in request order; at most two full suites at once, one overnight.'
 (lab/'config/house-decisions').write_text('test-slot: '+rule+'\n')
 (lab/'state/request.status').write_text('needs-decision [key=test-slot]: requesting a full suite slot\nneeds-decision [key=design]: choose REST or RPC\n')
 out=call('fm-wake-drain.sh')
 (ev/'long-rule-drain.txt').write_text(out)
 assert rule in out and out.count(rule)==1
 log.append(f'Observed complete {len(rule)} character rule, including final overnight limit, exactly once.\n')
 (lab/'config/house-decisions').write_text('test-slot: grant first\ntest-slot: grant last\n')
 out=call('fm-wake-drain.sh')
 assert 'is malformed, so no key is treated as a house decision' in out
 assert 'under the home\'s rule:' not in out
 (lab/'config/house-decisions').write_text('test-slot: '+rule+'\n')
 call('fm-send.sh','request','--resolve-key','test-slot','Granted the one overnight slot.',expected=6,actor='branch')
 call('fm-send.sh','request','--resolve-key','test-slot','Granted the one overnight slot.')
 status=(lab/'state/request.status').read_text()
 assert 'resolved [key=test-slot]' in status
 assert 'resolved [key=design]' not in status
 (lab/'state/request.status').write_text(status+'needs-decision [key=test-slot]: follow-up suite needs slot\n')
 call('fm-afk-contract.sh','enter','--words','strange, I did not touch ssh or the desktop this time')
 call('fm-send.sh','request','--resolve-key','test-slot','Wait for the existing overnight slot owner.',actor='branch')
 inbox='\n'.join(p.read_text() for p in sorted((lab/'state/request.inbox').glob('*.msg')))
 assert 'Granted the one overnight slot.' in inbox
 assert 'Wait for the existing overnight slot owner.' in inbox
 (ev/'house-inbox.txt').write_text(inbox)
 out=call('fm-wake-drain.sh')
 assert '[key=design]' in out
 assert '[key=test-slot]' not in out
 call('fm-afk-contract.sh','archive')
 (lab/'state/request.status').write_text((lab/'state/request.status').read_text()+'needs-decision [key=test-slot]: new request after return\n')
 call('fm-send.sh','request','--resolve-key','test-slot','Granted.',actor='branch',expected=6)
 log.append('Observed MAIN delivery attended, branch delivery away, return refusal, durable keyed closes, and preservation of the unrelated design decision.\n')
finally:
 (ev/'house-cli.txt').write_text('\n'.join(log))
