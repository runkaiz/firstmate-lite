import os, pathlib, subprocess, time, shutil, hashlib, json
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M5TETBKV45J8FE1S494BH8ZK')
evidence=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M5TETBKV45J8FE1S494BH8ZK')
lab=root/'.test-validation/live'
env=os.environ.copy()
for k in list(env):
    if k.startswith('FM_') or k in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','GIT_DIR','GIT_WORK_TREE','GIT_COMMON_DIR','GIT_INDEX_FILE'):
        env.pop(k,None)
env.update(FM_HOME=str(lab), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1')
log=open(evidence/'live-cli.log','w')
def run(*args, expected=0, timeout=15):
    start=time.monotonic()
    p=subprocess.run(args,env=env,cwd=root,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=timeout)
    log.write('$ '+' '.join(args)+'\n'+p.stdout+f'EXIT={p.returncode} elapsed={time.monotonic()-start:.3f}s\n');log.flush()
    assert p.returncode==expected,(args,p.returncode,p.stdout)
    return p.stdout
runner=None
try:
    run('bin/fm-lab-home.sh','create',str(lab))
    (lab/'state/retired.meta').write_text('kind=secondmate\nremote_host=unreachable.invalid\nwindow=fm-retired\n')
    (lab/'state/retired.status').write_text('working: retained private record\n')
    (lab/'data/retired').mkdir()
    (lab/'data/retired/report.md').write_text('Disposable preservation sentinel\n')
    def records():
        return {str(x.relative_to(lab)):hashlib.sha256(x.read_bytes()).hexdigest() for x in lab.rglob('*') if x.is_file()}
    before=records()
    out=run('bin/fm-crew-state.sh','retired'); assert 'retired-supervisor' in out
    run('bin/fm-brief.sh','--secondmate','retired','unused','unused',expected=1)
    run('bin/fm-spawn.sh','--secondmate','retired','unused',expected=2)
    run('bin/fm-teardown.sh','retired',expected=1)
    after=records()
    assert all(after.get(k)==v for k,v in before.items())
    log.write('Preserved all original disposable private records byte-for-byte.\n')
    package=evidence/'file-signal-package'
    shutil.copytree(root/'docs/examples/process-event-extension',package,dirs_exist_ok=True)
    run('bin/fm-extension.mjs','bind',str(package.resolve()),'--adapter','file-signal','--trust-same-user-code','--consent','artifact-references')
    signal=lab/'completion.txt'
    registration=run('bin/fm-procevent.sh','register-extension','file-signal','live-source','--config-ref','file:'+str(signal))
    owner=next(line.split(': ',1)[1] for line in registration.splitlines() if line.startswith('owner-token: '))
    source=lab/'state/procevent/live-source.source'
    original=source.read_bytes()
    runner_log=open(evidence/'live-runner.log','w')
    runner=subprocess.Popen(['bin/fm-procevent.sh','start','live-source'],cwd=root,env=env,stdout=runner_log,stderr=subprocess.STDOUT)
    # The extension lifecycle lock proves the real host has begun resolving/polling.
    deadline=time.monotonic()+10
    lock=lab/'state/procevent/.extension-binding-lifecycle.lock'
    while time.monotonic()<deadline:
        if lock.exists() or lock.is_symlink(): break
        time.sleep(.02)
    time.sleep(.5)
    assert runner.poll() is None,'runner exited before replacement'
    out=run('bin/fm-procevent.sh','register-extension','file-signal','live-source','--config-ref','replacement',expected=1,timeout=5)
    assert 'prior runner remains active' in out
    out=run('bin/fm-procevent.sh','register','lavish','live-source','--','/bin/echo','replacement',expected=1,timeout=5)
    assert 'prior runner remains active' in out
    assert source.read_bytes()==original,'active registration changed'
    signal.write_text('Real file signal: build completed\n')
    assert runner.wait(timeout=15)==0
    runner=None;runner_log.close()
    result=lab/'state/procevent-inbox/live-source.1.result'
    assert 'Real file signal: build completed' in result.read_text()
    shutil.copyfile(result,evidence/'live-result.txt')
    run('bin/fm-procevent.sh','handled','live-source','1')
    run('bin/fm-procevent.sh','retire','live-source','--if-owner',owner)
    assert not source.exists()
    registration=run('bin/fm-procevent.sh','register-extension','file-signal','live-source','--config-ref','file:'+str(signal))
    owner=next(line.split(': ',1)[1] for line in registration.splitlines() if line.startswith('owner-token: '))
    run('bin/fm-procevent.sh','retire','live-source','--if-owner',owner)
    log.write('Active replacement refused promptly; original signal captured; replacement allowed after completion and explicit retirement.\n')
finally:
    if runner is not None:
        (lab/'completion.txt').write_text('cleanup\n')
        try: runner.wait(timeout=20)
        except subprocess.TimeoutExpired: runner.terminate();runner.wait(timeout=5)
    if lab.exists():
        for item in lab.rglob('*'):
            if not item.is_symlink(): item.chmod(item.stat().st_mode | 0o200)
        shutil.rmtree(lab)
    log.write('Disposable lab removed.\n');log.close()
