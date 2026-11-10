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
EVIDENCE = ROOT / '.ahoy-validation/preservation'
LAB = ROOT / 'c'
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

run([ROOT/'bin/fm-lab-home.sh','create',LAB])
try:
    (LAB/'tmux').mkdir()
    recorded=json.loads(Path('/home/runkai/.no-mistakes/evidence/01M73T4Y8AEWYHTMC8P13ECBWT/live-real-worker-complete.json').read_text())
    assert any(x['state']=='done' for x in recorded['in_flight'])
    chat('completion-recorded-worker',recorded)
finally:
    sp.run(['tmux','-L','fm-lab','kill-server'],env=dict(ENV,TMUX_TMPDIR=str(LAB/'tmux')),capture_output=True)
    shutil.rmtree(LAB)
