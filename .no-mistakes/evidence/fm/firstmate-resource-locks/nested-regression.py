import os, pathlib, subprocess, tempfile, signal, time, shutil
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ')
case=pathlib.Path(tempfile.mkdtemp(prefix='nested-regression-',dir=ROOT/'.validation-tmp'))
prior=case/'prior-resource-lock.sh'
prior.write_bytes(subprocess.check_output(['git','show','306472b:bin/fm-resource-lock.sh'],cwd=ROOT))
prior.chmod(0o700)
declaration=case/'resource-locks'
declaration.write_text('suite 1 full suite\ngpu 1 GPU commands\n')
try:
    for label,script in [('before-306472b',prior),('after-3a5df1d',ROOT/'bin/fm-resource-lock.sh')]:
        runtime=case/label
        runtime.mkdir()
        env=dict(os.environ,XDG_RUNTIME_DIR=str(runtime),FM_RESOURCE_LOCK_POLL_SECS='.05')
        held=runtime/'nested-held'
        release=runtime/'release'
        ran=runtime/'competitor-ran'
        procs=[]
        handles=[]
        def launch(args,name):
            f=(runtime/(name+'.log')).open('w')
            handles.append(f)
            p=subprocess.Popen(list(map(str,args)),env=env,stdout=f,stderr=subprocess.STDOUT,start_new_session=True)
            procs.append(p)
            return p
        def await_(predicate):
            end=time.monotonic()+6
            while not predicate():
                assert time.monotonic()<end,'Timed out waiting for product observation'
                time.sleep(.05)
        try:
            nested=launch([script,'run','--file',declaration,'suite','--',script,'run','--file',declaration,'gpu','--','sh','-c',': > "$1"; while [ ! -e "$2" ]; do sleep .1; done','_',held,release],'nested')
            await_(held.exists)
            competitor=launch([script,'run','--file',declaration,'suite','--','touch',ran],'competitor')
            time.sleep(1.3)
            entered=ran.exists()
            print(label+': nested GPU command is still running; competing suite entered='+str(entered),flush=True)
            assert entered == (label=='before-306472b')
            release.touch()
            assert nested.wait(6)==0
            assert competitor.wait(6)==0 and ran.exists()
            print(label+': after nested exit, competitor has run.',flush=True)
            for path in runtime.glob('*.log'): print(path.name+'\n'+path.read_text(),flush=True)
        finally:
            for p in procs:
                try: os.killpg(p.pid,signal.SIGTERM)
                except ProcessLookupError: pass
            for p in procs: p.wait(timeout=5)
            for f in handles:f.close()
    print('Reproduced premature outer-lock release before the fix; the target retains the outer lock until nested execution finishes.',flush=True)
finally:
    shutil.rmtree(case)
