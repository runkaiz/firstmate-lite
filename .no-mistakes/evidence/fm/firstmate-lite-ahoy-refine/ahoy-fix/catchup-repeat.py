import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess as sp
import time

ROOT=Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73T4Y8AEWYHTMC8P13ECBWT')
EV=ROOT/'.ahoy-validation/evidence-after-repeat'
LAB=ROOT/'l'
ENV={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','NO_MISTAKES_')) and k!='TMUX'}
ENV.update(FM_HOME=str(LAB),TMPDIR=str(ROOT/'.ahoy-validation/tmp'),TMUX_TMPDIR=str(LAB/'tmux'),GIT_CEILING_DIRECTORIES=str(LAB))
LOG=[]
def run(args):
    p=sp.run([str(a) for a in args],cwd=ROOT,env=ENV,text=True,capture_output=True,timeout=90)
    LOG.append('$ '+shlex.join([str(a) for a in args])+'\n'+p.stdout+p.stderr)
    assert p.returncode==0,p.stdout+p.stderr
    return p.stdout
def queue(*args): return run([ROOT/'bin/fm-queue.py',*args,'--file',LAB/'data/backlog.md'])
try:
    run([ROOT/'bin/fm-lab-home.sh','create',LAB])
    (LAB/'tmux').mkdir()
    queue('add','delivered','Repair the importer retry logic','--kind','ship')
    queue('add','followup','Publish the importer guide','--kind','ship','--blocked-by','delivered')
    queue('add','disappeared','Investigate the previous import route','--kind','ship')
    queue('start','disappeared')
    (LAB/'state/disappeared.meta').write_text(f'window=fm-lab:absent\nworktree={LAB}/projects/disappeared\nproject=example\nharness=claude\nkind=ship\nmode=no-mistakes\n')
    initial=run([ROOT/'bin/fm-bearings-snapshot.sh','--json','--record-look'])
    (EV/'live-away-before.json').write_text(initial)
    queue('done','delivered','--pr','https://github.com/ahoy-lab/example/pull/3')
    queue('done','disappeared')
    (LAB/'state/disappeared.meta').unlink()
    before=(LAB/'data/backlog.md').read_bytes()
    command=['claude','-p','--no-session-persistence','--setting-sources','project','--settings','{"disableAllHooks":true}','--strict-mcp-config','--mcp-config','{"mcpServers":{}}','--tools','Bash,Read,Skill','--allowedTools','Bash,Read,Skill','--permission-mode','dontAsk','--output-format','stream-json','--verbose','--append-system-prompt','You are Firstmate in a disposable lab. Only perform the read-only Ahoy catch-up in the environment FM_HOME. Do not inspect other homes or run any lifecycle commands.','/ahoy']
    script=shlex.join(command)+' > '+shlex.quote(str(EV/'native-ahoy-away-stream.jsonl'))+' 2> '+shlex.quote(str(EV/'native-ahoy-away-stderr.log'))+'\ntouch '+shlex.quote(str(LAB/'finished'))+'\nread -r keep_pane\n'
    (LAB/'primary.sh').write_text(script)
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={LAB}','bash '+shlex.quote(str(LAB/'primary.sh'))])
    for _ in range(180):
        if (LAB/'finished').exists():break
        time.sleep(1)
    else:raise RuntimeError('Native catch-up did not complete')
    rows=[json.loads(line) for line in (EV/'native-ahoy-away-stream.jsonl').read_text().splitlines()]
    result=next(r for r in rows if r.get('type')=='result')
    assert not result.get('is_error'),result
    (EV/'native-ahoy-away.md').write_text(result['result']+'\n')
    print(result['result'],flush=True)
    assert before==(LAB/'data/backlog.md').read_bytes(),'Catch-up changed queue'
    # Read the actual executable's serialized public tool result, not its source.
    observed=[]
    for r in rows:
        if r.get('type')=='user':
            for c in r['message']['content']:
                if c.get('type')=='tool_result':
                    text=c.get('content','')
                    if not isinstance(text,str):continue
                    start=text.find('{')
                    if start>=0:
                        try:
                            obj,_=json.JSONDecoder().raw_decode(text[start:])
                            if obj.get('schema')=='fm-bearings.v1':observed.append(obj)
                        except (json.JSONDecodeError,AttributeError):pass
    assert len(observed)==1, f'Expected one real gather, got {len(observed)}'
    after=observed[0]
    (EV/'live-away-after.json').write_text(json.dumps(after,indent=2)+'\n')
    changes=after['since_last_look']['changes']
    assert any(x['surface']=='landed' and x['current'].endswith('/3') for x in changes)
    assert any(x['surface']=='moving' and x['title']=='Investigate the previous import route' and x['current']=='no longer observed' for x in changes)
    assert any(x['surface']=='next' and x['title']=='Publish the importer guide' and json.loads(x['previous'])==['-','delivered'] and json.loads(x['current'])==['-','-'] for x in changes)
    assert {x['id'] for x in after['landed']}=={'delivered'}
    assert not after['decisions_open']
    checkpoint=(LAB/'state/ahoy-last.json').read_text()
    (EV/'live-away-checkpoint.json').write_text(checkpoint)
    assert len(checkpoint)<2048
    assert not list((LAB/'data').glob('status-report-*'))
finally:
    sp.run(['tmux','-L','fm-lab','kill-server'],env=ENV,capture_output=True)
    (EV/'live-away-cli.log').write_text('\n'.join(LOG))
    if LAB.exists():shutil.rmtree(LAB)
