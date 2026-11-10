import copy, json, os, pathlib, shutil, subprocess, time, sys

root = pathlib.Path(os.environ['PWD'])
evidence = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73GH5ZSPN2J2WFM07SKPNBK')
lab = root / '.l'
copies = root / '.phase-test/copies'
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key in ('TMUX', 'TMUX_PANE', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'CODEX_HOME', 'CLAUDE_CONFIG_DIR', 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE', 'GIT_COMMON_DIR', 'OPENAI_API_KEY', 'ANTHROPIC_API_KEY', 'ANTHROPIC_AUTH_TOKEN', 'CODEX_API_KEY'):
        env.pop(key, None)
env.update(HOME=str(lab/'user'), FM_HOME=str(lab), TMUX_TMPDIR=str(lab/'tmux'), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', TMPDIR=str(root/'.phase-test/tmp'), DISABLE_AUTOUPDATER='1')

def run(args, check=True, extra=None):
    p = subprocess.run([str(x) for x in args], cwd=root, env=extra or env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=85)
    if check and p.returncode:
        raise RuntimeError(f'{args}: exit={p.returncode}\n{p.stdout}')
    return p

def tmux(*args, **kw):
    return run(['tmux', '-L', 'fm-lab', *args], **kw)

base = {'schemaVersion':6,'providers':[{'provider':'codex','accountKey':'codex-home','state':{'status':'fresh','stale':False},'windows':[{'id':'weekly','percentRemaining':25,'resetsAt':'2099-01-01T00:00:00Z','pace':{'burnMultiple':0.5,'timeRemainingPercent':20,'projectionConfidence':'established'}}],'quotaSemantics':{'status':'known','effectiveAvailability':[{'scope':'all_models','status':'known','effectivePercentRemaining':25,'boundedBy':['weekly'],'runway':{'status':'through_reset','projectionConfidence':'established'}}]}}]}
results = []
extra_batch = '--extra' in sys.argv
cli_failure_batch = '--cli-failure' in sys.argv
batch_prefix = 'cli-failure-' if cli_failure_batch else ('extra-' if extra_batch else '')
log = open(evidence/(batch_prefix+'live-spawn.log'), 'w')
def note(s):
    print(s, flush=True)
    log.write(s+'\n'); log.flush()

try:
    run(['bash', 'bin/fm-lab-home.sh', 'create', lab])
    for directory in ('tmux','user','worker','supervisor','bin','project'):
        (lab/directory).mkdir()
    env['CODEX_HOME'] = str(lab/'supervisor')
    env['PATH'] = str(lab/'bin') + ':' + env['PATH']
    (lab/'bin/quota-axi').write_text('''#!/usr/bin/env python3
import os,json,pathlib
lab=pathlib.Path(os.environ['FM_HOME'])
context=os.environ.get('CODEX_HOME','unset')
with open(lab/'state/probes.jsonl','a') as f: f.write(json.dumps({'context':context,'argv':__import__('sys').argv[1:]})+'\\n')
data='supervisor.json' if context.endswith('/supervisor') else ('worker.json' if context.endswith('/worker') else 'filtered.json')
print((lab/data).read_text())
''')
    (lab/'bin/quota-axi').chmod(0o755)
    (lab/'supervisor.json').write_text(json.dumps(base))
    (lab/'filtered.json').write_text('{}')
    config = lab/'config'
    (config/'crew-harness').write_text('codex\n')
    (config/'worktree-allocator').write_text('git\n')
    (config/'git-worktree-root').write_text(str(copies)+'\n')
    (config/'keep-ai-trailers').touch()
    (lab/'state/.last-watcher-beat').touch()
    run(['git','-C',lab/'project','init','-q','-b','main'])
    run(['git','-C',lab/'project','-c','user.name=Live Test','-c','user.email=live@example.invalid','commit','-q','--allow-empty','-m','Disposable live project'])
    pane_env=dict(env, CODEX_HOME=str(lab/'worker'))
    tmux('new-session','-d','-s','primary','-x','110','-y','32','-c',str(root),'bash --noprofile --norc',extra=pane_env)
    tmux('set-option','-g','default-shell','/bin/bash')
    tmux('set-option','-g','default-command','bash --noprofile --norc')
    env['TMUX'] = tmux('display-message','-p','#{socket_path},#{pid},0').stdout.strip()
    version=run(['codex','--version']).stdout.strip()
    feature=run(['codex','-c','service_tier="fast"','--enable','fast_mode','features','list'])
    supported=any(line.split()[0:1]==['fast_mode'] and line.split()[-1]=='true' for line in feature.stdout.splitlines())
    (evidence/'installed-codex-features.txt').write_text(version+'\n'+feature.stdout)
    note('Real product: fm-spawn.sh, native Git allocator, private tmux fm-lab socket, installed '+version)
    note('Quota inputs are disposable schema-6 data. Codex has an empty disposable home: no operator data, login, or model request is used.')
    def spawn(name, expected, model='gpt-6', opt=True, modifier=None, allow=None, relaunch=False, task=None, harness='codex', scout=False, raw=False):
        task=task or ('live-'+name.replace('.', '-'))
        quota=copy.deepcopy(base)
        if modifier: modifier(quota['providers'][0])
        (lab/'worker.json').write_text(json.dumps(quota))
        flag=config/'worker-fast-mode'
        if opt: flag.touch()
        else: flag.unlink(missing_ok=True)
        allowfile=config/'launch-env-allowlist'
        if allow is None: allowfile.unlink(missing_ok=True)
        else: allowfile.write_text(allow)
        if not relaunch:
            d=lab/'data'/task; d.mkdir()
            (d/'brief.md').write_text("# Task\n## Captain's intent\nVerify the isolated service decision.\n## Firstmate spec\nDisposable validation; no project changes.\n")
            args=[task,lab/'project','--backend','tmux']
            if scout: args+=['--scout']
            else: args+=['--mode','local-only','--yolo','off']
            args+=['codex features list'] if raw else ['--harness',harness]
        else:
            oldmeta=(lab/'state'/(task+'.meta')).read_text()
            wt=next(line.split('=',1)[1] for line in oldmeta.splitlines() if line.startswith('worktree='))
            tmux('respawn-pane','-k','-c',wt,'-t','primary:fm-'+task,'bash --noprofile --norc')
            time.sleep(.4)
            args=[task,'--relaunch']
        if model is not None and not raw: args+=['--model',model]
        p=run(['bash','bin/fm-spawn.sh',*args],check=False)
        note('\nSCENARIO '+name+'\n'+p.stdout)
        (evidence/(name+'-spawn.txt')).write_text(p.stdout)
        assert p.returncode==0, p.stdout
        meta=(lab/'state'/(task+'.meta')).read_text()
        actual=next(line.split('=',1)[1] for line in meta.splitlines() if line.startswith('launch_service_control='))
        assert actual==expected, (name,actual,expected)
        launch_files=list((lab/'state'/(task+'.launch')).glob('launch.*.sh'))
        if not launch_files:
            launch_files=list((lab/'state').glob('**/launch.*.sh'))
            launch_files=[p for p in launch_files if task in str(p)]
        # Metadata is the public decision contract; persist it with actual pane output.
        (evidence/(name+'-meta.txt')).write_text(meta)
        time.sleep(.7)
        pane=tmux('capture-pane','-p','-t','primary:fm-'+task,'-S','-60').stdout
        (evidence/(name+'-pane.txt')).write_text(pane)
        note('Observed launch_service_control='+actual)
        results.append({'name':name,'expected':expected,'actual':actual,'result':'pass'})
        return task
    fast='codex-fast' if supported else 'codex-default'
    if cli_failure_batch:
        (lab/'worker/config.toml').write_text('model = []\n')
        spawn('worker-cli-probe-rejected-normal','codex-default')
    elif extra_batch:
        spawn('scout-opt-in',fast,scout=True)
        spawn('claude-remains-normal','claude-fast-disabled',harness='claude',model=None)
        spawn('raw-command-unmodified','unverified',raw=True)
        task=spawn('relaunch-initial-normal','codex-default',opt=False)
        spawn('relaunch-enables-fast',fast,relaunch=True,task=task)
        spawn('relaunch-tight-quota-normal','codex-default',relaunch=True,task=task,modifier=lambda p:p['windows'][0].update(percentRemaining=1))
    else:
        healthy=spawn('opt-in-at-2.5x-boundary',fast)
        spawn('default-off','codex-default',opt=False)
        spawn('omitted-model','codex-default',model=None)
        spawn('default-model','codex-default',model='default')
        spawn('slightly-insufficient-runway','codex-default',modifier=lambda p:p['windows'][0]['pace'].update(burnMultiple=.5001))
        spawn('stale-quota','codex-default',modifier=lambda p:p['state'].update(stale=True))
        spawn('unknown-pace','codex-default',modifier=lambda p:p['windows'][0].pop('pace'))
        spawn('second-bounding-window-tight','codex-default',modifier=lambda p:(p['windows'].append(dict(p['windows'][0],id='session',percentRemaining=24)),p['quotaSemantics']['effectiveAvailability'][0]['boundedBy'].append('session')))
        spawn('expired-reset','codex-default',modifier=lambda p:p['windows'][0].update(resetsAt='2000-01-01T00:00:00Z'))
        spawn('exhausted-model-bound','codex-default',modifier=lambda p:p['quotaSemantics']['effectiveAvailability'].append({'scope':'model:gpt-6','status':'known','effectivePercentRemaining':0,'runway':{'status':'exhausted_now'}}))
        spawn('exhausted-product-bound','codex-default',modifier=lambda p:p['quotaSemantics']['effectiveAvailability'].append({'scope':'product:gpt-6','status':'known','effectivePercentRemaining':0,'runway':{'status':'exhausted_now'}}))
        spawn('worker-account-tight-supervisor-healthy','codex-default',modifier=lambda p:p['windows'][0].update(percentRemaining=1))
        spawn('allowlist-removes-worker-account','codex-default',allow='')
        spawn('allowlist-retains-worker-account',fast,allow='CODEX_HOME\nFM_HOME\n')
        spawn('relaunch-rechecks-disabled-opt-in','codex-default',opt=False,relaunch=True,task=healthy)
    (evidence/(batch_prefix+'destination-probes.jsonl')).write_text((lab/'state/probes.jsonl').read_text())
    (evidence/(batch_prefix+'results.json')).write_text(json.dumps(results,indent=2)+'\n')
finally:
    tmux('kill-server',check=False)
    shutil.rmtree(lab,ignore_errors=True)
    shutil.rmtree(copies,ignore_errors=True)
    note('Private tmux server stopped and disposable lab/project/copies removed.')
    log.close()
