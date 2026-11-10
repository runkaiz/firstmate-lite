import json,datetime
from pathlib import Path
E=Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
source=(E/'round3-chat-driver.py').read_text().split("q('add','ahoy-worker'")[0]
exec(source)
(L/'data/backlog.saved.md').rename(L/'data/backlog.md')
(L/'state/ahoy-last.json').unlink(missing_ok=True)
run('bash','bin/fm-captain-hold.sh','hold','active-call','--title','Choose the launch route','--reason','Choose route A or route B')
run('bash','bin/fm-captain-hold.sh','hold','conditional','--title','Revisit integration','--reason','Choose integration','--when','the upstream API stabilizes')
now=datetime.datetime.now(datetime.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
records=[]
for i in range(71):
    records.append(dict(url=f'https://github.com/example/lab/pull/{i+1}',kind='pr',pending=[],seen=[],notified=[],error=None,checked_at=now,verdict=None,observation=dict(state='open' if i<3 else 'merged',head='1'*40,draft=i<2,mergeable='mergeable',can_merge=False,review_decision='REVIEW_REQUIRED' if i==2 else '',checks=[],reviews=[],events=[])))
records[2]['observation']['checks']=[dict(name='CI',status='completed',conclusion='success')]
(L/'data/contribution-history').mkdir()
(L/'data/contribution-history/contributions.json').write_text(json.dumps(dict(schema='fm-contributions.v1',task='contribution-history',records=records)))
reply,snap=chat('actionable')
assert len(snap['decisions_open'])==1 and snap['decisions_open'][0]['id']=='active-call'
assert snap['contributions']['known']==71 and snap['contributions']['captain']==[],snap['contributions']
(L/'answer.txt').write_text('Use route A for this disposable validation scenario.\n')
run('bash','bin/fm-captain-hold.sh','answer','active-call','--decision-file',str(L/'answer.txt'))
run('bash','bin/fm-captain-hold.sh','answer','conditional','--decision-file',str(L/'answer.txt'))
reply,snap=chat('quiet-contributions')
assert not snap['gates'] and not snap['decisions_open'] and not snap['landed'] and not snap['in_flight']
assert snap['contributions']['known']==71 and not snap['contributions']['captain']
print('Actionable and quiet-contribution snapshots verified.')
