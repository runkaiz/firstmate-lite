import os, subprocess, pathlib, json, shutil
ROOT=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E481GYSFK0PPVV3M8EZBS6')
EVID=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E481GYSFK0PPVV3M8EZBS6')
HOME=ROOT/'.test-phase/live-home'
env=os.environ.copy()
for key in list(env):
    if key.startswith('FM_') or key in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','NO_MISTAKES_GATE'):
        env.pop(key)
env['FM_HOME']=str(HOME)
env['TMPDIR']=str(ROOT/'.test-phase/tmp')
transcript=[]
def run(name,*args,expected=0,extra=None):
    e=env.copy(); e.update(extra or {})
    p=subprocess.run([str(ROOT/'bin'/name),*args],cwd=ROOT,env=e,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    transcript.extend(['$ '+name+' '+' '.join(args),p.stdout,'exit='+str(p.returncode)+'\n'])
    assert p.returncode==expected,(name,p.returncode,p.stdout)
    return p.stdout

def absent(out):
    for text in ('No phone channel','reach:','expected return:','Expected return:','spend cap:','Spend cap:','reach_channels:','expected_return:','spend_max_concurrent_workers:'):
        assert text not in out,(text,out)

results=[]
try:
    run('fm-lab-home.sh','create',str(HOME))
    words='Continue approved work.\nKeep this line exactly.\n'
    wordfile=HOME/'words.txt'; wordfile.write_text(words)
    out=run('fm-afk-launch.sh','enter','--words-file',str(wordfile)); absent(out)
    assert 'Away posture (recorded)' in out
    record=HOME/'state/.afk-contract'; old=record.read_bytes(); absent(old.decode())
    assert run('fm-afk-contract.sh','words')==words
    run('fm-afk-contract.sh','validate')
    absent(run('fm-afk-launch.sh','enter')); assert record.read_bytes()==old
    out=run('fm-afk-return.sh','begin'); absent(out)
    assert 'Continue approved work.' in out and not record.exists()
    run('fm-afk-return.sh','guard')
    results.append({'name':'Enter, refresh, and return from away mode with verbatim words and no channel, return-time, or budget fields','result':'pass','live':True})
    for flag,value in [('--expected-return','2026-11-14T10:00:00Z'),('--spend','1'),('--reach','phone')]:
        out=run('fm-afk-launch.sh','enter',flag,value,expected=2)
        assert not record.exists()
    run('fm-afk-contract.sh','enter','--words','Standing instructions')
    old=record.read_bytes()
    for flag,value in [('--expected-return','2026-11-14T10:00:00Z'),('--spend','1')]:
        run('fm-afk-launch.sh','enter',flag,value,expected=2)
        assert record.read_bytes()==old
    run('fm-afk-contract.sh','archive')
    results.append({'name':'Retired return-time, budget, and channel options fail without creating or changing an away record','result':'pass','live':True})
    for version in (1,2):
        legacy=f"version: {version}\nentered: 2026-11-14T01:00:00Z\nentered_epoch: 1794618000\nexpected_return: invalid-unused\nreach_channels: phone\nreach_announced: No phone channel is configured.\nspend_max_concurrent_workers: invalid-unused\nconfirmed: 2026-11-14T01:00:00Z\nconfirmed_epoch: 1794618000\nwords: |-\n  Continue approved work.\n"
        if version==1: legacy+='clauses:\n  - id: 1\n    action: merge\nrefused:\nmerge_grants:\n'
        record.write_text(legacy); old=record.read_bytes()
        run('fm-afk-contract.sh','validate')
        assert run('fm-afk-contract.sh','words')=='Continue approved work.'
        absent(run('fm-afk-contract.sh','readback'))
        absent(run('fm-afk-launch.sh','enter')); assert record.read_bytes()==old
        archived=pathlib.Path(run('fm-afk-contract.sh','archive').strip())
        assert archived.read_bytes()==old
        run('fm-afk-contract.sh','validate','--path',str(archived))
    results.append({'name':'Existing v1 and v2 away records ignore even malformed retired fields while refresh and archive preserve their bytes','result':'pass','live':True})
    out=run('fm-afk-contract.sh','enter',extra={'FM_AFK_MODE':'quiet'}); absent(out)
    assert run('fm-afk-contract.sh','mode').strip()=='quiet'
    assert 'nothing waits for your return' in out
    run('fm-afk-contract.sh','archive')
    results.append({'name':'Quiet mode still records a present captain and holds nothing for return','result':'pass','live':True})
finally:
    (EVID/'live-away-cli.log').write_text('\n'.join(transcript))
    (EVID/'live-away-results.json').write_text(json.dumps(results,indent=2)+'\n')
    shutil.rmtree(HOME,ignore_errors=True)
print(json.dumps(results,indent=2))
