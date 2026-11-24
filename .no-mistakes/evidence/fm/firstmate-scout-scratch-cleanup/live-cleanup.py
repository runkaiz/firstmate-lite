import os, subprocess, pathlib, shutil, json, hashlib, shlex
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M87TMQ0134RQA58XJAG82EYZ')
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M87TMQ0134RQA58XJAG82EYZ')
W=R/'.test-cleanup-live'
SOCKET=str(R/'.fm-lab')
env={k:v for k,v in os.environ.items() if not (k.startswith('FM_') or k.startswith('GIT_') or k.startswith('TASKS_AXI') or k in ['TMUX','TMUX_PANE'])}
env.update(GIT_CONFIG_GLOBAL='/dev/null',GIT_CONFIG_NOSYSTEM='1',GIT_AUTHOR_NAME='Cleanup Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Cleanup Lab',GIT_COMMITTER_EMAIL='lab@example.invalid',TMPDIR=str(W),TMUX=SOCKET+',0,0')
results=[]
log=(E/'live-cleanup.log').open('w',buffering=1)
def run(args,e=None,ok=True,cwd=R):
    cp=subprocess.run([str(x) for x in args],cwd=cwd,env=e or env,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,text=True,timeout=90)
    log.write('$ '+shlex.join(str(x) for x in args)+'\n'+cp.stdout+f'[exit {cp.returncode}]\n')
    if ok and cp.returncode: raise RuntimeError(cp.stdout)
    return cp

def git(p,*args,**kw): return run(['git','-C',p,*args],**kw)
def digest(p): return hashlib.sha256(p.read_bytes()).hexdigest()
def scenario(name):
    c=W/name; c.mkdir(parents=True); home=c/'home'; proj=c/'project'; copies=c/'copies'
    run(['bash',R/'bin/fm-lab-home.sh','create',home]); e=env|{'FM_HOME':str(home)}
    proj.mkdir(); git(proj,'init','-q','-b','main')
    (proj/'README.md').write_text('Original report prototype\n')
    (proj/'image.bin').write_bytes(bytes(range(256))*4)
    (proj/'delete-me.txt').write_text('deletion prototype\n')
    git(proj,'add','.'); git(proj,'commit','-qm','base')
    base=git(proj,'rev-parse','HEAD').stdout.strip()
    (home/'config/worktree-allocator').write_text('git\n')
    (home/'config/git-worktree-root').write_text(str(copies)+'\n')
    (home/'config/backlog-backend').write_text('manual\n')
    (home/'data/projects.md').write_text('- project [local-only]\n')
    allocation=run(['bash','-c','. "$1/bin/fm-git-worktree-lib.sh"; fm_git_worktree_allocate "$2/state" scout "$2" "$3" "$4" "$5" refs/heads/main || exit; printf "LAB_WORKTREE=%s\\n" "$FM_GIT_WORKTREE_PATH"','_',R,home,proj,copies,base],e=e)
    allocated_path=allocation.stdout.split("LAB_WORKTREE=",1)[1].strip()
    wt=copies/'scout/worktree'; meta=home/'state/scout.meta'; task=home/'data/scout'; task.mkdir()
    kind='ship' if name=='ship-guard' else 'scout'
    meta.write_text(f'window=fm-lab-cleanup:fm-scout\nendpoint_task_id=scout\nbackend=tmux\nworktree={allocated_path}\nproject={proj}\nkind={kind}\nmode=local-only\nspawn_gen=s1792922400.123.456\nallocator=git\n')
    (home/'state/scout.status').write_text('working: designing\n' if name=='unfinished' else 'done: report delivered\n')
    if name!='no-report': (task/'report.md').write_text('Design report retained after cleanup.\n')
    if name not in ['no-inventory','no-report']:
        run(['bash',R/'bin/fm-captain-hold.sh','complete','scout','--none'],e=e)
    if name=='unique-commit':
        git(wt,'commit','--allow-empty','-qm','unique scout commit')
        git(proj,'merge','-q','--ff-only',git(wt,'rev-parse','HEAD').stdout.strip())
    (wt/'README.md').write_text('Original report prototype\nStaged prototype\n'); git(wt,'add','README.md')
    (wt/'README.md').write_text('Original report prototype\nStaged prototype\nUnstaged revision\n')
    (wt/'image.bin').write_bytes(b'\x00\xffSTAGED'+bytes(range(255))*3); git(wt,'add','image.bin')
    (wt/'image.bin').write_bytes(b'\x00\xffUNSTAGED'+bytes(range(255))*2)
    (wt/'delete-me.txt').unlink(); git(wt,'add','delete-me.txt')
    (wt/'added.txt').write_text('staged new design\n'); git(wt,'add','added.txt')
    (wt/'added.txt').write_text('staged new design\nunstaged new design\n')
    args=[]
    if name in ['generated','named','unnamed','partial-naming']:
        (proj/'.git/info/exclude').write_text('/build/\n')
        (wt/'build').mkdir(); (wt/'build/output').write_text('generated design preview\n')
        (wt/'__pycache__').mkdir(); (wt/'__pycache__/mod.pyc').write_bytes(b'\x00\xffBYTECODE')
    if name in ['named','unnamed','partial-naming']:
        (wt/'scratch-test.py').write_text('print("prototype")\n')
        if name=='named': args=['--preserve-untracked','scratch-test.py']
        if name=='partial-naming': args=['--preserve-untracked','build']
    if name=='patch-destination-failure': (task/'scratch').write_text('existing evidence must remain\n')
    if name=='unmerged':
        b=git(wt,'rev-parse','HEAD:README.md').stdout.strip(); s=git(wt,'rev-parse',':README.md').stdout.strip()
        cp=subprocess.run(['git','-C',str(wt),'update-index','--index-info'],input=f'0 {"0"*40}\tREADME.md\n100644 {b} 1\tREADME.md\n100644 {s} 2\tREADME.md\n',text=True,env=e,check=True)
    if name=='open-decision':
        (home/'state/scout.status').write_text('done: report delivered\nneeds-decision [key=prototype]: choose design\n')
    before_index=git(wt,'ls-files','--stage').stdout
    before_files={str(p.relative_to(wt)):digest(p) for p in wt.rglob('*') if p.is_file() and p.name!='.git'}
    owner=subprocess.Popen(['sleep','60'],cwd=wt,env=e) if name=='live-owner' else None
    try:
        cp=run(['bash',R/'bin/fm-teardown.sh','scout',*args],e=e,ok=False)
    finally:
        if owner is not None: owner.terminate(); owner.wait(timeout=5)
    success=name in ['tracked-and-binary','generated','named']
    if success:
        assert cp.returncode==0, cp.stdout
        assert not wt.exists() and not meta.exists() and not (home/'state/scout.git-worktree').exists()
        assert (task/'report.md').read_text()=='Design report retained after cleanup.\n'
        patches=list((task/'scratch').glob('teardown.*')); assert len(patches)==1
        git(proj,'apply','--index',patches[0]/'staged.patch'); git(proj,'apply',patches[0]/'unstaged.patch')
        after_index=git(proj,'ls-files','--stage').stdout; assert before_index==after_index
        for p,h in before_files.items():
            target=proj/p if (proj/p).exists() else task/'preserved-artifacts/files'/p
            assert target.exists() and digest(target)==h, p
        assert not (proj/'delete-me.txt').exists()
        log.write('OBSERVED: copy, reservation and metadata removed; report retained; saved patches restore exact staged index and all working-file hashes, including binary, added and deleted files.\n')
        (E/(name+'-recovered-state.txt')).write_text(git(proj,'status','--short').stdout+'\nRecovered file SHA256:\n'+json.dumps(before_files,indent=2)+'\n')
    else:
        assert cp.returncode!=0, 'unsafe cleanup accepted'
        expected={'no-report':'has no report','no-inventory':'completion gate','unfinished':'not reported completion','unique-commit':'recorded base','unnamed':'unclassified leftovers','unmerged':'unmerged paths','patch-destination-failure':'could not preserve tracked scout scratch','open-decision':'completion gate','live-owner':'process','ship-guard':'tracked changes are unique work'}
        assert expected[name] in cp.stdout, 'wrong refusal: '+cp.stdout
        assert wt.exists() and meta.exists() and (home/'state/scout.git-worktree').exists()
        assert before_index==git(wt,'ls-files','--stage').stdout
        for p,h in before_files.items(): assert digest(wt/p)==h,p
        if name not in ['partial-naming']: assert not list((task/'scratch').glob('teardown.*'))
        log.write('OBSERVED: cleanup refused; exact index, all working-file hashes, copy, metadata and reservation retained.\n')
        if name=='partial-naming':
            # Preservation may reverse edits before discovering an uncovered leftover; saved patches must still recover them.
            pass
    results.append({'scenario':name,'result':'pass','exit':cp.returncode})

try:
    W.mkdir(exist_ok=True)
    run(['tmux','-S',SOCKET,'-f','/dev/null','new-session','-d','-s','fm-lab-cleanup','-c',R,'bash --noprofile --norc'])
    for name in ['tracked-and-binary','generated','named','no-report','no-inventory','unfinished','unique-commit','unnamed','unmerged','patch-destination-failure','open-decision','live-owner','ship-guard']:
        log.write('\nSCENARIO '+name+'\n')
        try: scenario(name)
        except Exception as ex:
            results.append({'scenario':name,'result':'fail','error':str(ex)})
            log.write('ERROR: '+str(ex)+'\n')
    print(json.dumps(results,indent=2))
finally:
    run(['tmux','-S',SOCKET,'kill-server'],ok=False)
    if W.exists(): shutil.rmtree(W)
    pathlib.Path(SOCKET).unlink(missing_ok=True)
    (E/'live-results.json').write_text(json.dumps(results,indent=2)+'\n')
    log.close()
