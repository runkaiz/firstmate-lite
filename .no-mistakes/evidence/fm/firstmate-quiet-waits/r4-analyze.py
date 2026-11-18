from pathlib import Path
import json
import sys
base=Path(sys.argv[1])
r=json.loads((base/'r4-evaluation-results.json').read_text())
summary={}
for name, item in r.items():
    if name=='delivery':
        briefs=[(base/('r4-emitted-'+kind+'-brief.md')).read_text() for kind in item['modes']]
        rule='if that call times out, your very next tool call must be the identical wait (same command and arguments)'
        summary[name]={'pass':all(b.count(rule)==1 for b in briefs),'emitted_modes':item['modes']}
        continue
    flat=item['flat']
    wait=lambda v: (v.get('command','').lstrip().startswith(('./bin/fm-resource-lock.sh run', 'timeout 5s ./bin/fm-resource-lock.sh run')) if name!='long' else 'pbkdf2_hmac' in v.get('command',''))
    waits=[(i,v) for i,(k,v) in enumerate(flat) if k=='tool' and wait(v)]
    timeouts=[i for i,(k,v) in enumerate(flat) if k=='result' and 'Exit code 124' in v]
    retries=[]
    for i in timeouts:
        prev=next(v for k,v in reversed(flat[:i]) if k=='tool')
        following=flat[i+1] if i+1<len(flat) else None
        retries.append(bool(following and following[0]=='tool' and following[1]==prev))
    marker={'long':'LONG_COMMAND_COMPLETE','lock':'LOCKED_COMMAND_COMPLETE','timeout':'TIMEOUT_RECOVERY_COMPLETE'}[name]
    completed_indices=[i for i,(k,v) in enumerate(flat) if k=='result' and marker in v]
    end=completed_indices[-1] if completed_indices else len(flat)
    texts=[v for k,v in flat[waits[0][0]:end] if k=='text'] if waits else ['NO WAIT']
    pauses=[line for line in item['status'].splitlines() if line.startswith('paused ')]
    passed=bool(item['completed'] and completed_indices and waits and not texts and all(v.get('timeout')==600000 and not v.get('run_in_background') for _,v in waits))
    if name=='timeout':
        passed=passed and len(timeouts)>=2 and all(retries)
    else:
        passed=passed and len(waits)==1
    expected_pauses=0 if 'missed-pause' in str(base) else 1
    passed=passed and len(pauses)==expected_pauses
    summary[name]={'pass':passed,'completed':item['completed'],'elapsed_seconds':item['elapsed_seconds'],'wait_calls':len(waits),'tool_timeouts_ms':[v.get('timeout') for _,v in waits],'forced_timeouts':len(timeouts),'identical_immediate_retries':retries,'text_between_wait_and_completion':texts,'pause_declarations':len(pauses),'expected_pause_declarations':expected_pauses}
(base/'behavior-summary.json').write_text(json.dumps(summary,indent=2)+'\n')
print(json.dumps(summary,indent=2))
if not all(i['pass'] for i in summary.values()):
    sys.exit(1)
