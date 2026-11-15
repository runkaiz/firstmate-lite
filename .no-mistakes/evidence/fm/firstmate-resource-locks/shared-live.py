import pathlib,os,subprocess,time,signal,shutil
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ')
lab=root/'.live-validation/shared'
parent=lab/'parent'; child=lab/'child'; runtime=lab/'run'
for d in [parent/'config',child/'config',runtime]: d.mkdir(parents=True)
(parent/'config/resource-locks').write_text('gpu 1 GPU commands\n')
(child/'config/resource-locks').write_text('gpu 9 child-local conflicting declaration\n')
binding=child/'.fm-secondmate-parent'
binding.write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(parent)+'\n')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_')}
env.update(XDG_RUNTIME_DIR=str(runtime),FM_RESOURCE_LOCK_POLL_SECS='0.05')
script=str(root/'bin/fm-resource-lock.sh')
log=open('/home/runkai/.no-mistakes/evidence/01M7E5G3VE4WRF2AH7TSMB9MDJ/shared-home-live.log','w',buffering=1)
procs=[]
def start(home,args,name):
    f=open(lab/(name+'.log'),'w')
    p=subprocess.Popen([script]+args,env=dict(env,FM_HOME=str(home)),stdout=f,stderr=f,start_new_session=True)
    procs.append(p)
    print('$ FM_HOME='+str(home)+' '+repr([script]+args)+' pid='+str(p.pid),file=log)
    return p
def until(f):
    deadline=time.monotonic()+10
    while time.monotonic()<deadline:
        if f(): return
        time.sleep(.05)
    raise AssertionError('observable state never arrived')
try:
    holder=start(parent,['run','gpu','--','sh','-c',': > "$1/held"; while [ ! -e "$1/release" ]; do sleep .05; done','holder',str(lab)],'holder')
    until(lambda:(lab/'held').exists())
    args=['run','gpu','--','touch',str(lab/'child-ran')]
    waiter=start(child,args,'cancelled')
    until(lambda:'waiting for gpu' in (lab/'cancelled.log').read_text())
    assert not (lab/'child-ran').exists()
    print('OBSERVED child waits for root GPU slot despite its local gpu=9 declaration:\n'+(lab/'cancelled.log').read_text(),file=log)
    os.killpg(waiter.pid,signal.SIGTERM); waiter.wait(timeout=3)
    assert subprocess.run(['flock','-n',str(runtime/'gpu.lock'),'true']).returncode!=0
    print('OBSERVED cancelling waiter does not preempt root holder or execute payload.',file=log)
    retry=start(child,args,'retry')
    until(lambda:'waiting for gpu' in (lab/'retry.log').read_text())
    (lab/'release').touch(); assert holder.wait(timeout=3)==0
    assert retry.wait(timeout=5)==0 and (lab/'child-ran').exists()
    print('OBSERVED repeating same wrapped command runs after root holder exits:\n'+(lab/'retry.log').read_text(),file=log)
    binding.write_text('schema=fm-secondmate-parent.v1\nroute=local\nparent_home='+str(lab/'missing')+'\n')
    r=subprocess.run([script,'run','gpu','--','touch',str(lab/'MUST-NOT-RUN')],env=dict(env,FM_HOME=str(child)),text=True,capture_output=True)
    assert r.returncode==1 and not (lab/'MUST-NOT-RUN').exists()
    print('OBSERVED unreachable parent refuses instead of using permissive child-local declaration: exit='+str(r.returncode)+'\n'+r.stderr,file=log)
finally:
    for p in procs:
        if p.poll() is None: os.killpg(p.pid,signal.SIGTERM); p.wait(timeout=3)
    shutil.rmtree(lab)
    print('CLEANUP: shared-home fixture and all workload processes removed.',file=log)
    log.close()
