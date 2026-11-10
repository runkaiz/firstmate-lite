import os, pathlib, subprocess, json, shutil, time
ROOT=pathlib.Path.cwd()
EV=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73T4Y8AEWYHTMC8P13ECBWT')
LAB=ROOT/'.test-tmp/live-ahoy'
LAB.mkdir(exist_ok=True)
BASE=os.environ.copy()
for k in list(BASE):
    if k.startswith('FM_') and (k.endswith('_OVERRIDE') or k=='FM_HOME') or k in ['CLAUDECODE','CLAUDE_CODE_SESSION_ID']:
        BASE.pop(k,None)
BASE['TMPDIR']=str(ROOT/'.test-tmp')
BASE['GIT_CEILING_DIRECTORIES']=str(ROOT/'.test-tmp')
def run(args,env=BASE):
    r=subprocess.run([str(a) for a in args],env=env,cwd=ROOT,text=True,capture_output=True)
    if r.returncode: raise RuntimeError(f'{args}: {r.stderr} {r.stdout}')
    return r.stdout

def home(name):
    h=LAB/name
    run(['bin/fm-lab-home.sh','create',h])
    (h/'data/backlog.md').write_text('## In flight\n\n## Queued\n\n## Done\n')
    return h

def env(h): return dict(BASE, FM_HOME=str(h))
def q(h,*args): return run(['bin/fm-queue.py',*args,'--file',h/'data/backlog.md'])
def snap(h,label,record=True):
    args=['bin/fm-bearings-snapshot.sh','--json']+(['--record-look'] if record else [])
    s=run(args,env(h)); (EV/(label+'.json')).write_text(s)
    return json.loads(s)
def chat(h,label):
    before=(h/'data/backlog.md').read_bytes()
    args=['claude','-p','/ahoy','--setting-sources','','--settings','{"disableAllHooks":true,"autoMemoryEnabled":false}',
        '--tools','Bash,Read,Skill','--allowedTools','Bash,Read,Skill','--strict-mcp-config','--no-session-persistence',
        '--output-format','stream-json','--verbose','--append-system-prompt',
        'This is an isolated Firstmate Ahoy live evaluation. Session startup has already completed. Use the project Ahoy skill and the FM_HOME environment supplied to this process. Read only this disposable home and this project. Do not perform lifecycle, supervision, project probes or startup.']
    r=subprocess.run(args,env=env(h),cwd=ROOT,text=True,capture_output=True,timeout=240)
    (EV/(label+'.jsonl')).write_text(r.stdout)
    (EV/(label+'.stderr')).write_text(r.stderr)
    records=[]
    for line in r.stdout.splitlines():
        try: records.append(json.loads(line))
        except ValueError: pass
    result=next((x for x in reversed(records) if x.get('type')=='result'),{})
    text=result.get('result',r.stdout)
    (EV/(label+'.md')).write_text(text+'\n')
    print(label, r.returncode, text,flush=True)
    assert r.returncode==0 and not result.get('is_error'), result
    assert (h/'data/backlog.md').read_bytes()==before, 'chat changed queue'
    assert (h/'state/ahoy-last.json').exists(),'chat did not gather checkpoint'
    return text

h=home('mixed')
q(h,'add','delivered','Repair the importer retry logic','--kind','ship')
q(h,'add','followup','Publish the importer guide','--kind','ship','--blocked-by','delivered')
snap(h,'mixed-before')
q(h,'done','delivered','--pr','https://github.com/ahoy-lab/example/pull/3')
snap(h,'mixed-transition',False)
chat(h,'native-ahoy-away')
chat(h,'native-ahoy-unchanged')

h=home('quiet')
chat(h,'native-ahoy-quiet-first')
chat(h,'native-ahoy-quiet-repeat')

h=home('quiet-counts')
(h/'data/history').mkdir()
records=[]
for i in range(71):
    records.append({'url':f'https://github.com/ahoy-lab/example/pull/{100+i}','kind':'pr','checked_at':'2026-11-10T00:00:00Z','error':None,'pending':[],'seen':[],
        'observation':{'state':'merged','head':'a'*40,'draft':False,'mergeable':'mergeable','can_merge':False,'checks':[],'reviews':[],'events':[],'review_decision':''}})
(h/'data/history/contributions.json').write_text(json.dumps({'schema':'fm-contributions.v1','task':'history','records':records}))
snap(h,'quiet-counts-before')
chat(h,'native-ahoy-quiet-counts')

h=home('incomplete')
(h/'data/unreadable').mkdir()
(h/'data/unreadable/contributions.json').write_text('unreadable saved contribution\n')
snap(h,'incomplete-before')
for i in range(3): chat(h,f'native-ahoy-incomplete-{i+1}')

h=home('completion')
q(h,'add','implementation','Finish importer error handling','--kind','ship')
(h/'state/implementation.meta').write_text('window=missing:fm-implementation\nharness=claude\nkind=ship\nmode=direct-PR\nproject=example\npr=https://github.com/ahoy-lab/example/pull/4\n')
(h/'state/implementation.status').write_text('done: implementation finished, publication/CI verification skipped\n')
snap(h,'completion-before')
chat(h,'native-ahoy-completion')
print('LIVE_CHAT_COMPLETE',flush=True)
