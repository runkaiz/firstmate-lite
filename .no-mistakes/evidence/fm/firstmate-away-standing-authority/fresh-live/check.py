from pathlib import Path
import json, subprocess
ev=Path('/home/runkai/.no-mistakes/evidence/01M7E4EMMHJV5XTAZSM4MWEZTN/fresh-live')
root=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E4EMMHJV5XTAZSM4MWEZTN')
fixture=json.loads((ev/'fixture.json').read_text())
def state(stage): return json.loads((ev/stage/'product-state.json').read_text())
landed,occupied,second,third,dispatch,ready=[state(s) for s in ('landed','occupied','second-grant','third-grant','dispatch','ready')]
assert landed['demo_main']==fixture['heads']['approved']
assert landed['other_main']==fixture['initial']['other']
for task,before in fixture['metadata_before'].items():
    assert landed[task+'.meta']==before
    assert ready[task+'.meta']==before
assert 'Granted:' in landed['slot1.inbox/001.msg']
assert 'Wait:' in landed['slot2.inbox/001.msg'] and 'slot1' in landed['slot2.inbox/001.msg']
assert 'Wait:' in landed['slot3.inbox/001.msg'] and 'slot2' in landed['slot3.inbox/001.msg']
assert 'No: wait for slot1' in occupied['slot2.inbox/002.msg']
assert 'Granted: slot1 released' in second['slot2.inbox/003.msg']
assert 'Wait: slot2' in second['slot3.inbox/002.msg']
assert 'Granted: slot1 and slot2 have released' in third['slot3.inbox/003.msg']
assert 'needs-decision [key=design]' in ready['slot3.status']
assert 'resolved [key=design]' not in ready['slot3.status']
for s in (occupied,ready):
    assert s['restricted.meta']==fixture['metadata_before']['restricted']
assert '+yolo' in (ev/'occupied/projects.md').read_text()
for name in ('restricted','unapproved'):
    project='demo' if name=='restricted' else 'other'
    assert subprocess.run(['git','-C',str(root/'.l/projects'/project),'merge-base','--is-ancestor',fixture['heads'][name],'main']).returncode==1
assert 'yolo=on\n' in dispatch['queued-fix.meta']
assert 'mode=local-only\n' in dispatch['queued-fix.meta']
assert 'queued-fix,Fix demo queued answer,in_flight' in dispatch['queue']
assert '+yolo' not in (ev/'dispatch/projects.md').read_text()
assert (ev/'dispatch/afk-contract').read_text()==(ev/'third-grant/afk-contract').read_text()
assert 'strange, I did not touch ssh or the desktop this time' in (ev/'landed/afk-contract').read_text()
assert '42' == (root/'.l/projects/demo/queued_answer.txt').read_text().strip()
assert '\tfailed\t' not in (ev/'ready/supervision-host.log').read_text()
observations={
 'approved_landing': {'initial':fixture['initial']['demo'],'landed_exact_validated_head':landed['demo_main'],'dispatch_metadata':'unchanged'},
 'overnight_scheduling': ['slot1 granted','slot2 and slot3 wait','renewed slot2 denied while occupied','slot1 released -> slot2 granted, slot3 waits','slot2 released -> slot3 granted'],
 'house_rule': '519-character rule retained its final overnight one-suite constraint in the real supervisor decisions',
 'authority_boundaries': ['explicit restriction retained with registry +yolo','other project unmerged','unregistered design question remains open'],
 'queued_dispatch': {'state':'in_flight','mode':'local-only','yolo':'on','registry_yolo':'off','worker':'real Codex processed brief, validated and committed the fix','final_main':ready['demo_main'],'queued_answer.txt':42},
 'limitations': 'Suite tasks are disposable status/inbox requests with live placeholder endpoints. Real supervisor answers and actual durable inbox delivery were exercised; no repository full suites or native slot-worker receipt were claimed. Fixture cleanup refusals preserved missing-generation and live endpoints as expected; whole lab will be removed.'
}
(ev/'observations.json').write_text(json.dumps(observations,indent=2)+'\n')
print(json.dumps(observations,indent=2))
