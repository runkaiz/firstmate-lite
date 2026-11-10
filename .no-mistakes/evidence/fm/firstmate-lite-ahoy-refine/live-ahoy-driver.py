import datetime as dt
import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess as sp
import time

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73T4Y8AEWYHTMC8P13ECBWT')
EVIDENCE = Path('/home/runkai/.no-mistakes/evidence/01M73T4Y8AEWYHTMC8P13ECBWT')
LAB = ROOT / 'l'
ENV = {k: v for k, v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'NO_MISTAKES_'))}
ENV.update(FM_HOME=str(LAB), TMPDIR=str(ROOT / '.ahoy-validation/tmp'), GIT_CEILING_DIRECTORIES=str(LAB))
TRANSCRIPT = []

def run(args, **kw):
    p = sp.run([str(a) for a in args], cwd=ROOT, env=ENV, text=True, capture_output=True, timeout=90, **kw)
    if p.returncode:
        raise RuntimeError(f'{args}: {p.returncode}\n{p.stdout}\n{p.stderr}')
    return p.stdout

def queue(*args):
    out = run([ROOT/'bin/fm-queue.py', *args, '--file', LAB/'data/backlog.md'])
    TRANSCRIPT.append('$ bin/fm-queue.py ' + shlex.join(args) + '\n' + out)
    return out

def hold(*args, good=True):
    p = sp.run([str(ROOT/'bin/fm-captain-hold.sh'), *args], cwd=ROOT, env=ENV, text=True, capture_output=True, timeout=60)
    TRANSCRIPT.append('$ bin/fm-captain-hold.sh ' + shlex.join(args) + f'\nexit={p.returncode}\n' + p.stdout+p.stderr)
    assert (p.returncode == 0) == good, p.stdout+p.stderr

def snap(name, *flags):
    before = (LAB/'data/backlog.md').read_bytes()
    output = run([ROOT/'bin/fm-bearings-snapshot.sh', '--json', '--record-look', *flags])
    (EVIDENCE/(name+'.json')).write_text(output)
    assert before == (LAB/'data/backlog.md').read_bytes(), 'Ahoy mutated queue'
    TRANSCRIPT.append(f'$ bin/fm-bearings-snapshot.sh --json --record-look {shlex.join(flags)}\n' + output)
    return json.loads(output)

def chat(name, snapshot, prompt='/ahoy'):
    # A real, authenticated Claude print-mode engine consumes the current skill
    # and freshly generated product output. No fabricated engine or responses.
    system = 'You are Firstmate, the captain\'s assistant. Follow this loaded Ahoy skill.\n' + (ROOT/'.agents/skills/ahoy/SKILL.md').read_text()
    user = prompt + '\n\nThe gather command has just been run in this disposable home. Its fresh JSON output follows:\n' + json.dumps(snapshot)
    (EVIDENCE/(name+'-input.json')).write_text(json.dumps({'prompt':user,'system':system}, indent=2))
    command = ['claude','-p','--no-session-persistence','--setting-sources','', '--settings', '{"disableAllHooks":true}', '--strict-mcp-config', '--mcp-config','{"mcpServers":{}}', '--tools','', '--output-format','json','--system-prompt',system,user]
    result_path = EVIDENCE/(name+'-engine.json')
    shell = shlex.join(command) + ' > ' + shlex.quote(str(result_path)) + ' 2> ' + shlex.quote(str(EVIDENCE/(name+'-stderr.log')))
    tmux_env = dict(ENV, TMUX_TMPDIR=str(LAB/'tmux'))
    sp.run(['tmux','-L','fm-lab','kill-server'],env=tmux_env,capture_output=True)
    # Nonzero geometry is established before starting the real CLI.
    launch = sp.run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',str(ROOT),'-e',f'FM_HOME={LAB}', shell],env=tmux_env,capture_output=True,text=True)
    assert launch.returncode == 0, launch.stderr
    for _ in range(180):
        if result_path.exists():
            try:
                result=json.loads(result_path.read_text())
                if 'result' in result or result.get('is_error'):
                    break
            except json.JSONDecodeError:
                pass
        time.sleep(1)
    else:
        raise RuntimeError('Claude did not return a result within 180 seconds')
    capture=sp.run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary'],env=tmux_env,capture_output=True,text=True)
    sp.run(['tmux','-L','fm-lab','kill-server'],env=tmux_env,capture_output=True)
    assert not result.get('is_error'), result
    text=result['result']
    (EVIDENCE/(name+'.md')).write_text(text+'\n')
    TRANSCRIPT.append(f'$ claude -p [current Ahoy skill + fresh {name} snapshot; private fm-lab socket; 120x40]\n'+text+'\n')
    print(name+': '+text,flush=True)
    return text

def clean_data():
    for name in ('data','state','config','projects'):
        shutil.rmtree(LAB/name)
        (LAB/name).mkdir()
    (LAB/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')

try:
    (LAB/'tmux').mkdir(exist_ok=True)
    clean_data()
    first=snap('live-first-look')
    assert first['since_last_look']=={'since':None,'changes':[]}
    chat('chat-quiet-first', first)
    quiet=snap('live-quiet-repeat')
    assert quiet['since_last_look']['since'] and quiet['since_last_look']['changes']==[]
    chat('chat-quiet-repeat', quiet)

    # Action-free contribution volume must not lengthen a quiet catch-up.
    for i in range(71):
        path=LAB/'data'/f'cached-{i}'
        path.mkdir()
        record={'url':f'https://github.com/ahoy-lab/example/issues/{i+1}', 'kind':'issue','pending':[], 'seen':[], 'notified':[], 'error':None,'checked_at':dt.datetime.now(dt.timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ'), 'verdict':None, 'observation':{'state':'open','checks':[],'reviews':[],'events':[],'ready':False}}
        (path/'contributions.json').write_text(json.dumps({'schema':'fm-contributions.v1','task':f'cached-{i}','records':[record]}))
    cached=snap('live-quiet-cached')
    assert cached['contributions']['known']==71 and cached['contributions']['checked']==71
    assert cached['contributions']['captain']==[]
    chat('chat-quiet-cached',cached)
    (LAB/'data/cached-0/contributions.json').write_text('unreadable JSON\n')
    broken=snap('live-quiet-incomplete')
    assert broken['contributions']['complete'] is False and broken['contributions']['unreadable_records']==1
    for i in range(3):
        chat(f'chat-quiet-incomplete-{i+1}',broken)

    clean_data()
    queue('add','shipped','Delivered a real fix','--kind','ship')
    queue('done','shipped','--pr','https://github.com/ahoy-lab/example/pull/1')
    queue('add','folded','Folded parked idea','--kind','idea')
    queue('done','folded')
    queue('add','plain-closed','Closed without a delivery')
    queue('done','plain-closed')
    title='Revisit upstream integration with a complete task title exceeding the previous sixty character cutoff'
    hold('hold','conditional','--title',title,'--reason','Choose integration route','--when','the upstream API stabilizes')
    hold('hold','dated','--title','Revisit the deployment region','--reason','Choose deployment region','--until','2099-01-01')
    hold('hold','now','--title','Choose the authentication provider','--reason','Use hosted login or an in-house implementation?')
    queue('add','next','Implement the approved import workflow with the complete title shown to the captain','--kind','ship')
    queue('add','blocked','Publish the importer','--kind','ship','--blocked-by','next')
    busy=snap('live-busy')
    assert {x['id'] for x in busy['landed']}=={'shipped'}
    assert all(x['artifact']!='-' for x in busy['landed'])
    assert {x['id'] for x in busy['decisions_open']}=={'now'}
    conditional=next(x for x in busy['gates'] if x['id']=='conditional')
    assert conditional['deferred'] and conditional['title']==title and 'upstream API stabilizes' in conditional['reason']
    detail=snap('live-busy-detail','--all-decisions')
    assert all(x.get('deferred') is True for x in detail['decisions_open'] if x['id'] in ('conditional','dated'))
    chat('chat-busy',busy)
    chat('chat-busy-detail',detail,'/ahoy detail')
    queue_before=(LAB/'data/backlog.md').read_bytes()
    hold('hold','conditional','--reason','Choose route','--when','condition','--until','2099-01-01',good=False)
    assert (LAB/'data/backlog.md').read_bytes()==queue_before
    (LAB/'answer.txt').write_text('Use hosted login.\n')
    hold('answer','now','--decision-file',str(LAB/'answer.txt'))
    queue('done','next')
    transition=snap('live-answered-and-unblocked')
    changes=transition['since_last_look']['changes']
    assert any(x['surface']=='call' and x['current']=='no longer observed' for x in changes)
    assert any(x['surface']=='next' and x['title'].startswith('Implement the approved') and x['current']=='no longer observed' for x in changes)
    assert any(x['surface']=='next' and x['title']=='Publish the importer' and json.loads(x['current'])==['-','-'] for x in changes)
    assert not any(x['surface']=='landed' for x in changes)
    chat('chat-transitions',transition)
    unchanged=snap('live-transition-repeat')
    assert unchanged['since_last_look']['changes']==[]
    (LAB/'state/ahoy-last.json').write_text('broken checkpoint')
    recovery=snap('live-checkpoint-recovery')
    assert recovery['since_last_look']['since'] is None
    checkpoint=json.loads((LAB/'state/ahoy-last.json').read_text())
    assert set(checkpoint)=={'schema','generated','rows'}
    assert len(list((LAB/'state').glob('ahoy-last*')))==1

    # A completion message and recorded PR do not establish publication or CI.
    clean_data()
    queue('add','complete','Complete the import workflow','--kind','ship')
    queue('start','complete')
    (LAB/'state/complete.meta').write_text(f'kind=ship\nmode=no-mistakes\nharness=claude\nwindow=fm-lab:complete\nworktree={LAB}/projects/complete\nproject=example\npr=https://github.com/ahoy-lab/example/pull/2\n')
    (LAB/'projects/complete').mkdir()
    (LAB/'state/complete.status').write_text('done: implementation complete; publication and CI remain unverified\n')
    complete=snap('live-completion')
    assert not complete['decisions_open'] and not complete['contributions']['captain']
    assert all(x['stage']!='PR ready' for x in complete['in_flight'])
    chat('chat-completion',complete)
finally:
    tmux_env=dict(ENV, TMUX_TMPDIR=str(LAB/'tmux'))
    sp.run(['tmux','-L','fm-lab','kill-server'],env=tmux_env,capture_output=True)
    (EVIDENCE/'live-cli-transcript.log').write_text('\n'.join(TRANSCRIPT))
    shutil.rmtree(LAB)
