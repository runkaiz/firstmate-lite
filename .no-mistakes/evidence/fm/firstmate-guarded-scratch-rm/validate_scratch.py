import os, pathlib, subprocess, tempfile, shutil, json
root=pathlib.Path.cwd()
evidence=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M6CEZ64EFAMTAQ1QWJ9XBEQS')
scratch=pathlib.Path(tempfile.mkdtemp(prefix='.scratch-validation-',dir=root))
log=[]
expected='When clearing scratch folders, use a guarded explicit path such as `rm -rf -- "${DIR:?}/sub"`, never `cd` then `rm -rf` with a relative glob.'
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k!='DIR'}
env['FM_HOME']=str(scratch/'home')
(scratch/'home').mkdir()
def run(args, env):
    r=subprocess.run(args,env=env,cwd=root,text=True,capture_output=True)
    log.append({'command':args,'DIR':env.get('DIR','<unset>'),'exit':r.returncode,'stdout':r.stdout,'stderr':r.stderr})
    return r
try:
    for state,value in [('unset',None),('empty',''),('hostile','$(touch '+str(scratch/'INJECTED')+') `false` *')]:
        for mode in ['no-mistakes','direct-PR','local-only','scout']:
            case=f'{mode}-{state}'
            e=env.copy()
            if value is not None: e['DIR']=value
            args=['bin/fm-brief.sh',case,'scratch-example']+(['--scout'] if mode=='scout' else ['--mode',mode])
            result=run(args,e)
            assert result.returncode==0, result.stderr
            brief=pathlib.Path(e['FM_HOME'])/'data'/case/'brief.md'
            text=brief.read_text()
            rules=text.split('# Rules',1)[1].split('\n# ',1)[0]
            assert rules.count(expected)==1, case
            assert not (scratch/'INJECTED').exists()
            log.append({'case':case,'generated_rule':next(x for x in rules.splitlines() if expected in x),'literal_guard_preserved':True})
            if state=='unset': shutil.copyfile(brief,evidence/f'{mode}-brief.md')
    command=next(x for x in rules.splitlines() if expected in x).split('`')[1]
    target=scratch/'folder with spaces [*]'
    (target/'sub').mkdir(parents=True)
    (target/'sub'/'discard.txt').write_text('scratch')
    (target/'keep.txt').write_text('retain')
    (scratch/'keep.txt').write_text('retain sibling')
    e=env.copy(); e['DIR']=str(target)
    result=run(['bash','-c',command],e)
    assert result.returncode==0
    assert not (target/'sub').exists()
    assert (target/'keep.txt').read_text()=='retain'
    assert (scratch/'keep.txt').read_text()=='retain sibling'
    log.append({'cleanup':'only explicit subfolder removed; parent and sibling retained','path':str(target)})
    for state,value in [('unset',None),('empty','')]:
        e=env.copy()
        if value is not None: e['DIR']=value
        result=run(['bash','-c',command],e)
        assert result.returncode!=0 and 'DIR' in result.stderr
        assert (target/'keep.txt').exists() and (scratch/'keep.txt').exists()
        log.append({'guard':state,'result':'shell refused before rm; sentinels retained'})
finally:
    shutil.rmtree(scratch)
    (evidence/'scratch-validation.json').write_text(json.dumps(log,indent=2)+'\n')
print('Real fm-brief CLI: 12 generated briefs verified across all ship modes and scout with unset, empty, and hostile DIR. Emitted command: explicit folder removed, neighboring files retained, unset and empty DIR refused. Disposable home removed.')
