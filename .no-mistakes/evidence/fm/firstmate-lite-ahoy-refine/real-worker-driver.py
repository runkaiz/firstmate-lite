import datetime as dt
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess as sp
import time

ROOT=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73T4Y8AEWYHTMC8P13ECBWT')
EV=Path('/home/runkai/.no-mistakes/evidence/01M73T4Y8AEWYHTMC8P13ECBWT')
LAB=ROOT/'l'
ENV={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','NO_MISTAKES_')) and k!='TMUX'}
ENV.update(FM_HOME=str(LAB),TMPDIR=str(ROOT/'.ahoy-validation/tmp'),TMUX_TMPDIR=str(LAB/'tmux'),GIT_CEILING_DIRECTORIES=str(LAB))

def run(args,check=True):
    p=sp.run([str(a) for a in args],cwd=ROOT,env=ENV,text=True,capture_output=True,timeout=90)
    if check:
        assert p.returncode==0, p.stdout+p.stderr
    return p.stdout

def snapshot(name):
    before=(LAB/'data/backlog.md').read_bytes()
    out=run([ROOT/'bin/fm-bearings-snapshot.sh','--json','--record-look'])
    (EV/(name+'.json')).write_text(out)
    assert before==(LAB/'data/backlog.md').read_bytes()
    return json.loads(out)

def native(label):
    system='You are the Firstmate supervisor in a disposable lab. Address the user as captain. Only perform the requested read-only Ahoy catch-up. The environment FM_HOME identifies all current data. Do not access other homes or run lifecycle actions.'
    cmd=['claude','-p','--no-session-persistence','--setting-sources','project','--settings','{"disableAllHooks":true}','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','Bash,Read,Skill','--allowedTools','Bash,Read,Skill','--permission-mode','dontAsk','--output-format','stream-json','--verbose','--append-system-prompt',system,'/ahoy']
    script=shlex.join(cmd)+' > '+shlex.quote(str(EV/(label+'-stream.jsonl')))+' 2> '+shlex.quote(str(EV/(label+'-stderr.log')))+'\ntouch '+shlex.quote(str(LAB/(label+'-finished')))+'\nread -r keep_pane\n'
    (LAB/'primary.sh').write_text(script)
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={LAB}', 'bash '+shlex.quote(str(LAB/'primary.sh'))])
    for _ in range(180):
        if (LAB/(label+'-finished')).exists(): break
        time.sleep(1)
    else: raise RuntimeError('Native Ahoy did not finish')
    rows=[json.loads(line) for line in (EV/(label+'-stream.jsonl')).read_text().splitlines()]
    result=next(r for r in rows if r.get('type')=='result')
    assert not result.get('is_error'),result
    (EV/(label+'.md')).write_text(result['result']+'\n')
    print(label+': '+result['result'],flush=True)
    run(['tmux','-L','fm-lab','kill-session','-t','primary'])
    return rows

try:
    run([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir()
    task=LAB/'projects/import-workflow'
    task.mkdir()
    run(['git','-C',task,'init','-q'])
    run(['git','-C',task,'-c','user.name=Lab','-c','user.email=lab@example.test','-c','commit.gpgsign=false','commit','--allow-empty','-qm','Isolated progress fixture'])
    run(['git','-C',task,'checkout','-qb','fm/import-workflow'])
    title='Implement the approved import workflow while preserving the full task title across the Ahoy glance'
    run([ROOT/'bin/fm-queue.py','add','import-workflow',title,'--kind','ship','--file',LAB/'data/backlog.md'])
    run([ROOT/'bin/fm-queue.py','start','import-workflow','--file',LAB/'data/backlog.md'])
    start=int(time.time())
    (LAB/'state/import-workflow.meta').write_text(f'window=worker:import-workflow\nworktree={task}\nproject=example\nharness=claude\nkind=ship\nmode=no-mistakes\nspawn_gen=s{start}.1.1\npr=https://github.com/ahoy-lab/example/pull/2\n')
    gen=run([ROOT/'bin/fm-busy-event.sh','arm',LAB/'state','import-workflow']).strip()
    busy=shlex.join([str(ROOT/'bin/fm-busy-event.sh'),'apply',str(LAB/'state'),'import-workflow','busy','--gen',gen,'--source','claude-hook','--event','user-prompt-submit'])
    idle=shlex.join([str(ROOT/'bin/fm-busy-event.sh'),'apply',str(LAB/'state'),'import-workflow','idle','--gen',gen,'--source','claude-hook','--event','stop'])
    settings={'hooks':{'UserPromptSubmit':[{'hooks':[{'type':'command','command':busy}]}], 'Stop':[{'hooks':[{'type':'command','command':idle}]}]}}
    (LAB/'state/import-workflow.status').write_text('working: implementing the import workflow\n')
    cmd=['claude','-p','--no-session-persistence','--setting-sources','','--settings',json.dumps(settings),'--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','','--output-format','json','--system-prompt','You are a concise programming assistant. Answer the user directly.','Explain the design and tradeoffs of an import workflow in 1200 words. Do not use tools.']
    script=shlex.join(cmd)+' > '+shlex.quote(str(EV/'real-worker-engine.json'))+' 2> '+shlex.quote(str(EV/'real-worker-stderr.log'))+'\nprintf "done: implementation finished; publication and CI unverified\\n" >> '+shlex.quote(str(LAB/'state/import-workflow.status'))+'\ntouch '+shlex.quote(str(LAB/'worker-finished'))+'\nread -r keep_pane\n'
    script_path=LAB/'worker.sh'
    script_path.write_text(script)
    run(['tmux','-L','fm-lab','new-session','-d','-s','worker','-n','import-workflow','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={LAB}', 'bash '+shlex.quote(str(script_path))])
    socket=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path}']).strip()
    ENV['TMUX']=socket+',0,0'
    for _ in range(60):
        if (LAB/'state/import-workflow.busy-state').exists() and 'busy' in (LAB/'state/import-workflow.busy-state').read_text():
            break
        time.sleep(1)
    moving=snapshot('live-real-worker-moving')
    row=next(r for r in moving['in_flight'] if r['id']=='import-workflow')
    print('moving:',row,flush=True)
    assert row['state']=='working' and row['stage']=='implementing', row
    assert row['name']==title and isinstance(row['elapsed_seconds'],int) and row['elapsed_seconds']>=0
    (EV/'real-worker-pane.txt').write_text(run(['tmux','-L','fm-lab','capture-pane','-p','-t','worker']))
    native('native-ahoy-moving')
    for _ in range(180):
        if (LAB/'worker-finished').exists(): break
        time.sleep(1)
    else: raise RuntimeError('Worker never finished')
    engine=json.loads((EV/'real-worker-engine.json').read_text())
    assert not engine.get('is_error'),engine
    complete=snapshot('live-real-worker-complete')
    row=next(r for r in complete['in_flight'] if r['id']=='import-workflow')
    print('complete:',row,flush=True)
    assert row['state']=='done' and row['stage']=='done',row
    assert not complete['decisions_open'] and not complete['contributions']['captain']
    assert any(r['id']=='import-workflow' and r['url'].endswith('/2') for r in complete['recorded_prs'])

    native('native-ahoy-completion')
    (EV/'live-real-checkpoint.json').write_text((LAB/'state/ahoy-last.json').read_text())
    (EV/'real-worker-status.log').write_text((LAB/'state/import-workflow.status').read_text())
finally:
    run(['tmux','-L','fm-lab','kill-server'],check=False)
    if LAB.exists(): shutil.rmtree(LAB)
