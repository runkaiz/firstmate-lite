import hashlib, json, os, pathlib, shlex, shutil, subprocess
root=pathlib.Path(os.environ['PWD'])
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73GH5ZSPN2J2WFM07SKPNBK')
token=hashlib.sha256(str((root/'.l').resolve()).encode()).hexdigest()
env=dict(os.environ, HOME=str(root/'.phase-test/user'), CODEX_HOME=str(root/'.phase-test/codex'))
for k in ('OPENAI_API_KEY','CODEX_API_KEY','ANTHROPIC_API_KEY','ANTHROPIC_AUTH_TOKEN'):
    env.pop(k,None)
output=ev/'generated-launches-and-consumer-results.json'
records=json.loads(output.read_text()) if output.exists() else []
for f in sorted(ev.glob('*-meta.txt')):
    meta=dict(line.split('=',1) for line in f.read_text().splitlines() if '=' in line)
    task=meta['endpoint_task_id']
    directory=pathlib.Path('/tmp')/('fm-'+task+'+'+token)
    source=directory/('launch.'+meta['spawn_gen']+'.sh')
    if not source.exists():
        continue
    launch=source.read_text()
    rec={'scenario':f.name[:-9],'service_control':meta['launch_service_control'],'generated_launch':launch}
    if meta['harness']=='codex' and rec['service_control']!='unverified':
        command=shlex.split(launch.split('/bin/sh -c ',1)[1])[0] if '/bin/sh -c ' in launch else launch
        flags=shlex.split(command.split('codex ',1)[1].split(' "$(')[0])
        proc=subprocess.run(['codex',*flags,'features','list'],text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,env=env,timeout=15)
        states={line.split()[0]:line.split()[-1] for line in proc.stdout.splitlines() if len(line.split())>=3}
        assert proc.returncode==0,proc.stdout
        assert states['hooks']=='false',states
        if rec['service_control']=='codex-fast': assert states['fast_mode']=='true',states
        rec.update(command=shlex.join(['codex',*flags,'features','list']),exit=proc.returncode,hooks=states['hooks'],fast_mode=states.get('fast_mode'))
    elif meta['harness']=='claude':
        assert 'CLAUDE_CODE_DISABLE_FAST_MODE=1' in launch
    elif rec['service_control']=='unverified':
        assert 'codex features list' in launch
        assert '--enable fast_mode' not in launch
    records=[r for r in records if r['scenario']!=rec['scenario']]+[rec]
(ev/'generated-launches-and-consumer-results.json').write_text(json.dumps(records,indent=2)+'\n')
for rec in records:
    print(rec['scenario']+': '+rec['service_control']+(' -> installed Codex exit=0, hooks='+rec['hooks']+', fast_mode='+str(rec['fast_mode']) if 'exit' in rec else ''))
for f in ev.glob('*-meta.txt'):
    meta=dict(line.split('=',1) for line in f.read_text().splitlines() if '=' in line)
    task=meta['endpoint_task_id']
    shutil.rmtree(pathlib.Path('/tmp')/('fm-'+task+'+'+token),ignore_errors=True)
    shutil.rmtree(pathlib.Path('/tmp')/('fm-'+task),ignore_errors=True)
# The first setup attempt used a dot in a tmux window name and was refused.
for task in ('live-opt-in-at-2.5x-boundary',):
    shutil.rmtree(pathlib.Path('/tmp')/('fm-'+task+'+'+token),ignore_errors=True)
    shutil.rmtree(pathlib.Path('/tmp')/('fm-'+task),ignore_errors=True)
print('Captured generated launch contracts, replayed exact Codex controls, removed known product temp files.')
