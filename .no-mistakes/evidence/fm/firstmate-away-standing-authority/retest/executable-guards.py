import os, pathlib, subprocess, json
root = pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E4EMMHJV5XTAZSM4MWEZTN')
ev = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E4EMMHJV5XTAZSM4MWEZTN/retest')
lab = root/'.live-test/edges'
env = dict(os.environ, FM_HOME=str(lab), GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
for k in list(env):
    if (k.startswith('FM_') and k != 'FM_HOME') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND'): env.pop(k)
log=[]
def run(*args, expected=0, actor='main', log_output=True, **kwargs):
    e=dict(env, FM_SUPERVISION_ACTOR=actor)
    p=subprocess.run(args, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, env=e, **kwargs)
    if log_output: log.append('$ '+ ' '.join(str(x) for x in args)+f' [actor={actor}]\n'+p.stdout+f'exit={p.returncode}\n')
    if expected is not None: assert p.returncode == expected, log[-1]
    return p.stdout.strip(), p.returncode
def cli(name,*args,**kw): return run(str(root/'bin'/name), *args, **kw)
def write(p,s): p.parent.mkdir(parents=True,exist_ok=True); p.write_text(s)
def ref(): return run('git','-C',str(project),'rev-parse','HEAD',log_output=False)[0]
try:
    cli('fm-lab-home.sh','create',str(lab))
    write(lab/'.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
    write(lab/'data/backlog.md','# Backlog\n\n## In flight\n- [ ] gate - Validated fix (repo: demo) (kind: ship)\n\n## Queued\n\n## Done\n')
    write(lab/'state/request.meta','window=primary:missing\nbackend=tmux\nharness=claude\nkind=ship\n')
    write(lab/'state/request.status','needs-decision [key=test-slot]: need one full-suite slot\nneeds-decision [key=design]: choose REST or RPC\n')
    write(lab/'config/house-decisions','test-slot: one full suite at once; grant in request order\n')
    cli('fm-wake-drain.sh')
    cli('fm-send.sh','request','--resolve-key','test-slot','Granted',actor='branch',expected=6)
    assert not (lab/'state/request.inbox').exists()
    env['FM_AFK_MODE']='quiet'
    cli('fm-afk-contract.sh','enter')
    env.pop('FM_AFK_MODE')
    cli('fm-send.sh','request','--resolve-key','test-slot','Granted',actor='branch',expected=6)
    assert not (lab/'state/request.inbox').exists()
    cli('fm-afk-contract.sh','archive')
    cli('fm-send.sh','request','--resolve-key','design','REST',actor='branch',expected=6)
    write(lab/'config/house-decisions','test-slot: grant first\ntest-slot: grant last\n')
    out,_=cli('fm-wake-drain.sh')
    assert 'is malformed, so no key is treated as a house decision' in out
    assert 'under the home\'s rule:' not in out
    project=lab/'projects/demo'; worker=lab/'worker'
    project.mkdir()
    run('git','init','-qb','main',str(project))
    run('git','-C',str(project),'commit','--allow-empty','-qm','initial')
    initial=ref()
    run('git','clone','-q',str(project),str(worker))
    run('git','-C',str(worker),'checkout','-qb','fm/gate')
    run('git','-C',str(worker),'commit','--allow-empty','-qm','validated fix')
    run('git','-C',str(project),'fetch','-q',str(worker),'fm/gate:fm/gate')
    meta=f'project={project}\nworktree={worker}\nkind=ship\nmode=local-only\nyolo=off\nbranch=fm/gate\n'
    write(lab/'state/gate.meta',meta)
    write(lab/'state/gate.status','done: validated ready\n')
    cli('fm-merge-local.sh','gate',actor='branch',expected=6)
    cli('fm-afk-contract.sh','enter','--words','strange, I did not touch the desktop this time')
    for status in ('failed: validation failed\n','needs-decision [key=design]: choose design\n'):
        write(lab/'state/gate.status',status)
        cli('fm-merge-local.sh','gate',actor='branch',expected=1)
        assert ref()==initial
    write(lab/'state/gate.status','done: validated ready\n')
    write(worker/'uncommitted','dirty\n')
    cli('fm-merge-local.sh','gate',actor='branch',expected=1)
    assert ref()==initial
    (worker/'uncommitted').unlink()
    cli('fm-captain-hold.sh','hold','gate','--reason','explicit captain restriction')
    cli('fm-merge-local.sh','gate',actor='branch',expected=1)
    assert ref()==initial
    write(lab/'answer.txt','Captain approves the validated head.\n')
    cli('fm-captain-hold.sh','answer','gate','--decision-file',str(lab/'answer.txt'),'--release')
    write(lab/'data/captain.md','Standing approval: land validated demo fixes through the next stable release.\n')
    write(lab/'data/projects.md','# Projects\n\n- demo [local-only] - yolo off\n')
    cli('fm-merge-local.sh','gate',actor='branch')
    expected=run('git','-C',str(worker),'rev-parse','HEAD',log_output=False)[0]
    log.append(f'Observed main={ref()} validated head={expected}; immutable task metadata unchanged={(lab/"state/gate.meta").read_text()==meta}\n')
    assert ref()==expected and (lab/'state/gate.meta').read_text()==meta
    cli('fm-afk-contract.sh','archive')
    cli('fm-merge-local.sh','gate',actor='branch',expected=6)
    log.append('All executable guard scenarios passed.\n')
finally:
    (ev/'executable-guards.txt').write_text('\n'.join(log))
