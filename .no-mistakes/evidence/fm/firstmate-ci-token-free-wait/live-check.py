import os, pathlib, subprocess, time, shutil

root = pathlib.Path.cwd()
lab = root / '.ci-validation/live'
evidence = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M64NQZNA4524FEW9H0MMA1A8')
lab.mkdir()
env = os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key.startswith('TASKS_AXI_'):
        env.pop(key)
env.update(FM_HOME=str(lab/'home'), FM_ROOT_OVERRIDE=str(root),
           FM_STATE_OVERRIDE=str(lab/'home/state'), FM_DATA_OVERRIDE=str(lab/'home/data'),
           FM_CONFIG_OVERRIDE=str(lab/'home/config'), FM_PROJECTS_OVERRIDE=str(lab/'home/projects'),
           FM_PROCEVENT_CLAIM_ROOT=str(lab/'claims'), NM_HOME=str(lab/'nm'),
           TMPDIR=str(root/'.ci-validation/tmp'), GIT_CONFIG_NOSYSTEM='1',
           GIT_CONFIG_GLOBAL='/dev/null')
for key in ('FM_HOME','FM_STATE_OVERRIDE','FM_DATA_OVERRIDE','FM_CONFIG_OVERRIDE','FM_PROJECTS_OVERRIDE','NM_HOME'):
    pathlib.Path(env[key]).mkdir(parents=True, exist_ok=True)
wt = lab/'repo'
wt.mkdir()
log = open(evidence/'live-cli-transcript.txt', 'w')
def run(args, expected=0, cwd=root):
    p = subprocess.run(args, cwd=cwd, env=env, text=True, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, timeout=25)
    command = ' '.join(map(str,args)).replace(str(lab), '<disposable-lab>').replace(str(root), '<worktree>')
    output = p.stdout.replace(str(lab), '<disposable-lab>').replace(str(root), '<worktree>')
    log.write('$ '+command+'\n'+output+f'[exit {p.returncode}]\n')
    log.flush()
    if expected is not None:
        assert p.returncode == expected, (command,p.returncode,p.stdout)
    return p.stdout
def note(message):
    log.write('\n'+message+'\n'); log.flush(); print(message, flush=True)
state = pathlib.Path(env['FM_STATE_OVERRIDE'])
adapter = root/'bin/fm-procevent-ci.sh'
runner = root/'bin/fm-procevent.sh'
pr = 'https://github.com/example/disposable/pull/1'
try:
    run(['git','init','-q','-b','fm/live-validation',str(wt)])
    run(['git','-C',str(wt),'-c','user.name=Validation','-c','user.email=validation@example.invalid',
         'commit','-qm','initial','--allow-empty'])
    note('Real no-mistakes CLI, isolated NM_HOME, no pipeline initialization or drive commands.')
    run(['no-mistakes','--version'])
    run(['no-mistakes','axi','status'], expected=None, cwd=wt)
    meta = state/'task.meta'
    meta.write_text(f'kind=ship\nmode=no-mistakes\nworktree={wt}\n')
    meta.chmod(0o600)
    for posture in ('ordinary','wait-no-turns'):
        if posture == 'wait-no-turns':
            (lab/'home/config/wait-no-turns').touch()
        run([str(root/'bin/fm-brief.sh'),posture,'example','--mode','no-mistakes'])
        brief = (lab/f'home/data/{posture}/brief.md').read_text()
        command_line = next(line for line in brief.splitlines() if line.startswith('When only CI remains running'))
        command = command_line.split('`')[1]
        (state/f'{posture}.meta').write_text(meta.read_text())
        (state/f'{posture}.meta').chmod(0o600)
        note(f'Generated {posture} worker handoff command reaches real eligibility guard.')
        out = run(['bash','-c',command],expected=1)
        assert 'no current run with a canonical PR' in out or 'cannot read no-mistakes run' in out
    assert not list((state/'procevent').glob('*.source'))
    note('Existing PR monitor refuses CI handoff before creating a second owner.')
    (state/'task.check.sh').touch()
    assert 'already has a PR/custom monitor' in run([str(adapter),'arm','task'],expected=1)
    (state/'task.check.sh').unlink()
    note('Registered CI ownership blocks both repeated handoff and merge monitoring.')
    run([str(runner),'register','ci','ci-livevalidation','--',str(adapter),'poll','task',str(wt),
         'LIVEVALIDATION','fm/live-validation',pr])
    assert 'CI wait already registered' in run([str(adapter),'arm','task'],expected=1)
    assert 'delegated CI wait' in run([str(root/'bin/fm-pr-check.sh'),'task',pr],expected=1)
    assert not (state/'task.check.sh').exists()
    note('Restart reconciliation starts the real adapter; nonexistent run becomes a durable monitoring-error wake.')
    run([str(runner),'reconcile'])
    for _ in range(100):
        results = list((state/'procevent-inbox').glob('ci-livevalidation.*.result'))
        queue = state/'.wake-queue'
        if results and queue.exists() and queue.stat().st_size:
            break
        time.sleep(.1)
    assert results and queue.stat().st_size
    result = results[0]
    log.write(result.read_text())
    log.write('\nWake queue:\n'+queue.read_text())
    assert 'monitor-error' in run([str(runner),'classify',str(result)])
    assert len(queue.read_text().splitlines()) == 1
    seq = result.name.removeprefix('ci-livevalidation.').removesuffix('.result')
    note('Acknowledgement is idempotent; another reconciliation neither repeats the wake nor restarts the terminal wait.')
    assert 'handled:' in run([str(runner),'handled','ci-livevalidation',seq])
    assert 'already-handled:' in run([str(runner),'handled','ci-livevalidation',seq])
    before = queue.read_text()
    run([str(runner),'reconcile'])
    assert queue.read_text() == before
    assert not (state/'procevent/ci-livevalidation.source').exists()
    run([str(runner),'list'])
    note('PASS: all real CLI refusal, monitor-exclusivity, error-capture and acknowledgement checks.')
finally:
    if (state/'procevent/ci-livevalidation.source').exists():
        run([str(runner),'retire','ci-livevalidation'],expected=None)
    log.close()
    shutil.rmtree(lab)
