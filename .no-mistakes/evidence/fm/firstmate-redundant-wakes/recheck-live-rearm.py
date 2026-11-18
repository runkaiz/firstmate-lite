from pathlib import Path
import os, subprocess, json, re, shlex, shutil, traceback, sys

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7RCW1DGVQEFV4XPMHQNTV34')
EVID = Path('/home/runkai/.no-mistakes/evidence/01M7RCW1DGVQEFV4XPMHQNTV34')
BASE = ROOT / '.test-selected-live'
SOCKET = ROOT / '.v'
ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'GIT_', 'TASKS_AXI_')) and k not in ('TMUX', 'TMUX_PANE', 'BASH_ENV')}
ENV.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Live lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Live lab', GIT_COMMITTER_EMAIL='lab@example.invalid', TMPDIR=str(BASE / 'tmp'))
LOG = (EVID / 'recheck-live-rearm-transcript.log').open('w')
RESULTS_FILE = EVID / 'recheck-live-rearm-results.json'
RESULTS = []

def run(args, env=None, check=True):
    e = ENV.copy(); e.update(env or {})
    LOG.write('$ ' + shlex.join(map(str,args)) + '\n'); LOG.flush()
    try:
        p = subprocess.run(list(map(str,args)), cwd=ROOT, env=e, text=True, stdout=subprocess.PIPE, stderr=subprocess.PIPE, timeout=45)
    except subprocess.TimeoutExpired as exc:
        LOG.write(f'TIMEOUT: {exc}\n'); LOG.flush(); raise
    LOG.write(p.stdout + p.stderr + f'[exit {p.returncode}]\n'); LOG.flush()
    if check and p.returncode: raise RuntimeError(f'{args}: {p.returncode}: {p.stderr}')
    return p

def cli(h, script, *args, extra=None):
    return run(['bash', ROOT/'bin'/script, *args], {'FM_HOME':str(h), **(extra or {})})

def shell(h, program, *args):
    return run(['bash', '-c', program, '_', ROOT, *args], {'FM_HOME':str(h)})

def write(p, value, mode=None):
    p.parent.mkdir(parents=True, exist_ok=True); p.write_text(value)
    if mode is not None: p.chmod(mode)
    LOG.write(f'LAB INPUT {p.relative_to(BASE)}:\n{value}\n'); LOG.flush()

def snapshot(h, label):
    # These are persisted public state contracts, not implementation-source assertions.
    data = {str(p.relative_to(h/'state')):p.read_text() for p in (h/'state').rglob('*') if p.is_file() and p.stat().st_size < 65536}
    out = EVID / ('recheck-live-rearm-'+label+'.json')
    out.write_text(json.dumps(data, indent=2)+'\n')
    LOG.write(f'PERSISTED STATE {label}:\n'+json.dumps(data,indent=2)+'\n'); LOG.flush()
    return data

def queue(h):
    p=h/'state/.wake-queue'
    return p.read_text() if p.exists() else ''

def rows(h):
    return [r.split('\t') for r in queue(h).splitlines()]

def wake(h, kind, key, reason):
    shell(h, '. "$1/bin/fm-wake-lib.sh"; fm_wake_append "$2" "$3" "$4"', kind, key, reason)

def ack(h):
    p=cli(h,'fm-wake-drain.sh')
    m=re.search(r'WAKE_ACK_REQUIRED:.*--ack-through (\d+) --recovery-generation ([A-Za-z0-9._-]+)',p.stderr)
    assert m, (p.stdout,p.stderr)
    cli(h,'fm-wake-drain.sh','--ack-through',m[1],'--recovery-generation',m[2])

def home(name):
    h=BASE/name
    cli(h,'fm-lab-home.sh','create',h)
    write(h/'config/supervision-host-off','')
    write(h/'config/backlog-backend','manual\n')
    p=h/'projects/repo'
    run(['git','init','-q','-b','main',p])
    run(['git','-C',p,'commit','-q','--allow-empty','-m','base'])
    return h,p

def meta(h, p, task='task-a', mode='no-mistakes', wt=None, allocator=None):
    text=f'window=fm-selected:fm-{task}\nendpoint_task_id={task}\nbackend=tmux\nharness=claude\nworktree={wt or p}\nproject={p}\nkind=ship\nmode={mode}\nbranch=fm/{task}\nspawn_gen=s1792922400.123.456\n'
    if allocator: text+=f'allocator={allocator}\n'
    write(h/f'state/{task}.meta',text,0o600)

FAKE_GH = r'''#!/usr/bin/env python3
import sys, os, json, re
from pathlib import Path
a=sys.argv[1:]; store=Path(os.environ['LOCAL_FORGE'])
with store.with_suffix('.log').open('w') as f:f.write(json.dumps(a)+'\n')
d=json.loads(store.read_text())
n=None
for x in a:
    m=re.search(r'/pull/(\d+)$',x)
    if m:n=m[1]
    if x.startswith('number='):n=x.split('=',1)[1]
if a[:2]==['pr','merge']:n=a[2]
r=d.get(n,{})
if a[:2]==['pr','merge']:
    assert a[a.index('--match-head-commit')+1]==r['head']
    if r.get('request')=='queue':r.update(state='OPEN',queued=True)
    else:r.update(state='MERGED',queued=False)
    store.write_text(json.dumps(d));print('local forge accepted');sys.exit(0)
if a[:2]==['api','graphql']:
    print('state='+r['state']);print('merged='+str(r['state']=='MERGED').lower());print('queued='+str(r.get('queued',False)).lower());print('base=main');sys.exit(0)
if a[:2]==['pr','view']:
    fields=a[a.index('--json')+1]
    if fields=='state':print(r['state'])
    elif fields=='headRefOid':print(r['head'])
    elif fields=='isDraft':print('{"isDraft":false}')
    elif 'statusCheckRollup' in fields:
        print(json.dumps(dict(state=r['state'],isDraft=False,mergeable='MERGEABLE',mergeStateStatus='CLEAN',headRefOid=r['head'],baseRefName='main',reviewDecision='APPROVED',statusCheckRollup=[dict(__typename='CheckRun',name='ci',status='COMPLETED',conclusion='SUCCESS')])) )
    elif fields=='headRefOid,reviewDecision':print(json.dumps(dict(headRefOid=r['head'],reviewDecision='APPROVED')))
    else:raise SystemExit('unexpected pr view '+repr(a))
    sys.exit(0)
if a and a[0]=='api':
    path=next((x for x in a if x.startswith('repos/')),'')
    if '/rules/branches/' in path:print('[]')
    elif '/branches/' in path:print('{"name":"main","protected":false}')
    elif '/check-runs' in path:print('[{"check_runs":[]}]')
    elif any(x in path for x in ('/comments','/reviews','/statuses')):print('[[]]')
    elif '/pulls/' in path:
        n=path.split('/pulls/')[1].split('/')[0];r=d[n]
        print(json.dumps(dict(state='open',user=dict(login='author'),head=dict(sha=r['head']),draft=False,mergeable=True,merged_at=None)))
    elif re.fullmatch(r'repos/[^/]+/[^/]+',path):print('{"permissions":{"push":false}}')
    else:raise SystemExit('unexpected api '+repr(a))
    sys.exit(0)
raise SystemExit('unexpected fake forge call '+repr(a))
'''

def setup_forge(h,p,kind):
    head=run(['git','-C',p,'rev-parse','HEAD']).stdout.strip()
    f=h/'forge.json'
    write(f,json.dumps({str(n):dict(head=head,state='OPEN',queued=False,request=kind) for n in (1,2)}))
    write(h/'fakebin/gh',FAKE_GH,0o700)
    # Prevent any unsupported fallback from touching a real account.
    for name in ('gh-axi','glab','gerrit-axi'):
        write(h/'fakebin'/name,'#!/bin/sh\necho "unexpected forge fallback" >&2\nexit 99\n',0o700)
    return {'LOCAL_FORGE':str(f),'PATH':str(h/'fakebin')+':'+ENV['PATH']}

def state(h,number,value):
    p=h/'forge.json';d=json.loads(p.read_text());d[str(number)].update(state=value,queued=False)
    write(p,json.dumps(d))

def watcher(h,e):
    return cli(h,'fm-watch.sh',extra={**e,'FM_CHECK_INTERVAL':'0','FM_POLL':'0.02','FM_HEARTBEAT':'999999','FM_SIGNAL_GRACE':'0'})

def stop_check(h):
    write(h/'state/z-stop.check.sh','#!/usr/bin/env bash\nprintf "stop-cycle\\n"\n',0o700)
    cli(h,'fm-check-register.sh','z-stop')

def assert_poll_absent(h):
    for suffix in ('check.sh','pr-poll','pr-poll-registration','pr-poll-retirement'):
        assert not (h/('state/task-a.'+suffix)).exists(),suffix

def merge_keys(h):
    return [r[3] for r in rows(h) if r[3].startswith('merged-task-a-')]

def scenario(name, fn):
    LOG.write('\n=== '+name+' ===\n');LOG.flush()
    try:
        fn(); RESULTS.append(dict(name=name,result='pass',live=True));print('PASS '+name,flush=True)
    except Exception as exc:
        LOG.write(traceback.format_exc());LOG.flush()
        RESULTS.append(dict(name=name,result='fail',live=True,error=str(exc)));print('FAIL '+name+': '+str(exc),flush=True)

def retirement():
    h,p=home('retirement')
    copy_root=BASE/'native-copies'
    write(h/'config/worktree-allocator','git\n');write(h/'config/git-worktree-root',str(copy_root)+'\n')
    head=run(['git','-C',p,'rev-parse','HEAD']).stdout.strip()
    for task in ('task-a','task-a-extra'):
        out=shell(h,'. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-git-worktree-lib.sh"; fm_git_worktree_allocate "$FM_HOME/state" "$2" "$FM_HOME" "$3" "$5" "$4" refs/heads/main || exit; printf "%s\\n" "$FM_GIT_WORKTREE_PATH"',task,p,head,copy_root)
        wt=Path(out.stdout.strip().splitlines()[-1]);meta(h,p,task,'local-only',wt,'git')
        write(h/f'state/{task}.status','done: task landed on local main\n')
    before_sibling=(h/'state/task-a-extra.meta').read_bytes()
    wake(h,'signal','task-a.status','signal: task-a.status')
    wake(h,'signal','task-a.turn-ended','signal: task-a.turn-ended')
    wake(h,'check','merged-task-a-https://github.com/lab/disposable/pull/1','check: merge landed: task-a https://github.com/lab/disposable/pull/1')
    wake(h,'check','inactive-outcome:aaaa','inactive terminal outcome awaiting captain presentation: child=task-a state=done')
    wake(h,'check','merged-task-a-extra-https://github.com/lab/disposable/pull/2','check: merge landed: task-a-extra https://github.com/lab/disposable/pull/2')
    wake(h,'check','inactive-outcome:bbbb','inactive terminal outcome awaiting captain presentation: child=task-a-extra state=done')
    wake(h,'signal','task-a-extra.status','signal: task-a-extra.status')
    wake(h,'check','new-event','new evidence for task-a')
    before=snapshot(h,'retirement-before')
    wt=Path(re.search(r'^worktree=(.+)$',(h/'state/task-a.meta').read_text(),re.M)[1])
    cli(h,'fm-teardown.sh','task-a')
    after=snapshot(h,'retirement-after')
    assert not wt.exists() and not (h/'state/task-a.meta').exists() and not (h/'state/task-a.status').exists()
    assert (h/'state/task-a-extra.meta').read_bytes()==before_sibling
    assert (h/'state/task-a-extra.status').exists()
    expected=['merged-task-a-extra-https://github.com/lab/disposable/pull/2','inactive-outcome:bbbb','task-a-extra.status','new-event']
    assert [r[3] for r in rows(h)]==expected,rows(h)
    original={r.split('\t')[3]:r for r in before['.wake-queue'].splitlines()}
    assert all(original[r.split('\t')[3]]==r for r in queue(h).splitlines())
    run(['git','-C',p,'worktree','list','--porcelain'])

def self_merge():
    h,p=home('self');meta(h,p);e=setup_forge(h,p,'self')
    cli(h,'fm-pr-check.sh','task-a','https://github.com/lab/disposable/pull/1',extra=e)
    write(h/'state/task-a.status','done: PR https://github.com/lab/disposable/pull/1 checks green\n')
    cli(h,'fm-pr-merge.sh','task-a','https://github.com/lab/disposable/pull/1',extra=e)
    first=snapshot(h,'self-after-merge')
    assert not merge_keys(h)
    assert 'task-a.pr-poll-merge-notified' in first
    assert len([k for k in first if k.endswith('.presented')])==1
    # Consume the ready status separately, then deliberately re-arm the handled PR.
    wake(h,'signal','task-a.status','signal: task-a.status');ack(h)
    stop_check(h)
    for attempt in (1,2):
        cli(h,'fm-pr-check.sh','task-a','https://github.com/lab/disposable/pull/1',extra=e)
        out=watcher(h,e)
        assert 'stop-cycle' in out.stdout and 'task-a.check.sh: merged' not in out.stdout,out.stdout
        assert not merge_keys(h);assert_poll_absent(h)
        snapshot(h,f'self-after-rearm-{attempt}');ack(h)

def async_merge(kind):
    h,p=home(kind);meta(h,p);e=setup_forge(h,p,'queue')
    url='https://github.com/lab/disposable/pull/1'
    cli(h,'fm-pr-check.sh','task-a',url,extra=e)
    if kind=='queued':
        out=cli(h,'fm-pr-merge.sh','task-a',url,extra=e)
        assert 'is queued' in out.stdout and not merge_keys(h),out.stdout
        assert not (h/'state/task-a.pr-poll-merge-notified').exists()
    stop_check(h)
    out=watcher(h,e)
    assert 'stop-cycle' in out.stdout and not merge_keys(h),out.stdout
    assert (h/'state/task-a.check.sh').exists()
    snapshot(h,kind+'-before-landing');ack(h)
    state(h,1,'MERGED')
    out=watcher(h,e)
    assert 'task-a.check.sh: merged' in out.stdout,out.stdout
    assert merge_keys(h)==['merged-task-a-'+url],rows(h)
    assert_poll_absent(h);snapshot(h,kind+'-first-notice');ack(h)
    # A fresh registration is a stronger duplicate check than an absent poll.
    cli(h,'fm-pr-check.sh','task-a',url,extra=e)
    out=watcher(h,e)
    assert 'stop-cycle' in out.stdout and not merge_keys(h),out.stdout
    assert_poll_absent(h);snapshot(h,kind+'-repeat-quiet');ack(h)
    url2='https://github.com/lab/disposable/pull/2'
    cli(h,'fm-pr-check.sh','task-a',url2,extra=e)
    state(h,2,'MERGED');out=watcher(h,e)
    assert 'task-a.check.sh: merged' in out.stdout,out.stdout
    assert merge_keys(h)==['merged-task-a-'+url2],rows(h)
    assert_poll_absent(h);snapshot(h,kind+'-distinct-pr');ack(h)
    out=watcher(h,e)
    assert 'stop-cycle' in out.stdout and not merge_keys(h),out.stdout
    snapshot(h,kind+'-final');ack(h)

try:
    assert not BASE.exists() and not SOCKET.exists()
    (BASE/'tmp').mkdir(parents=True)
    run(['tmux','-f','/dev/null','-S',SOCKET,'new-session','-d','-s','fm-selected','-x','120','-y','35','-c',ROOT,'bash --noprofile --norc'])
    ENV['TMUX']=run(['tmux','-S',SOCKET,'display-message','-p','-t','fm-selected','#{socket_path},#{pid},0']).stdout.strip()
    def rearm():
        h,p=home('rearm')
        copy_root=BASE/'native-copies'
        write(h/'config/worktree-allocator','git\n')
        write(h/'config/git-worktree-root',str(copy_root)+'\n')
        head=run(['git','-C',p,'rev-parse','HEAD']).stdout.strip()
        out=shell(h,'. "$1/bin/fm-wake-lib.sh"; . "$1/bin/fm-git-worktree-lib.sh"; fm_git_worktree_allocate "$FM_HOME/state" task-a "$FM_HOME" "$2" "$4" "$3" refs/heads/main || exit; printf "%s\\n" "$FM_GIT_WORKTREE_PATH"',p,head,copy_root)
        wt=Path(out.stdout.strip().splitlines()[-1])
        meta(h,p,'task-a','local-only',wt,'git')
        write(h/'state/task-a.status','done: task landed on local main\n')
        wake(h,'check','merged-task-a-https://github.com/lab/disposable/pull/1','check: merge landed: task-a https://github.com/lab/disposable/pull/1')
        shell(h,'. "$1/bin/fm-wake-lib.sh"; fm_recovery_marker_publish "$FM_HOME/state/.watcher-down" downtime')
        snapshot(h,'before-teardown')
        cli(h,'fm-teardown.sh','task-a')
        assert not queue(h),queue(h)
        snapshot(h,'after-teardown')
        for attempt in (1,2):
            out=cli(h,'fm-watch.sh',extra={'FM_POLL':'0.02','FM_HEARTBEAT':'0','FM_CHECK_INTERVAL':'999999'})
            assert 'heartbeat' in out.stdout and 'rearm-resurface' not in out.stdout,out.stdout
            assert not merge_keys(h)
            snapshot(h,f'watcher-{attempt}')
            ack(h)
    scenario('Retiring the only handled merge wake prevents redundant watcher rearm resurfacing',rearm)
finally:
    run(['tmux','-S',SOCKET,'kill-server'],check=False)
    if SOCKET.exists():SOCKET.unlink()
    if BASE.exists():shutil.rmtree(BASE)
    RESULTS_FILE.write_text(json.dumps(RESULTS,indent=2)+'\n')
    LOG.write('Disposable lab home, native copy, repository and private tmux server removed.\n');LOG.close()
if len(RESULTS)!=1 or RESULTS[0]['result']!='pass':raise SystemExit(1)
