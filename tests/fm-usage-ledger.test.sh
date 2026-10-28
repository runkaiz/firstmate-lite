#!/usr/bin/env bash
# Exercise the public CLI with synthetic native records, never live logs.
set -euo pipefail
# shellcheck source=tests/lib.sh
. "$(dirname "${BASH_SOURCE[0]}")/lib.sh"

python3 - "$ROOT" <<'PY'
import json
import os
from pathlib import Path
import shutil
import sqlite3
import subprocess
import sys
import tempfile

script = str(Path(sys.argv[1]) / 'bin/fm-usage-ledger.py')
secret = 'PRIVATE_SENTINEL_never_retain_627281'
with tempfile.TemporaryDirectory(prefix='fm-usage-test-') as tmp:
    root = Path(tmp)
    db = root / 'usage.sqlite'
    manifest = root / 'selected.json'
    when = '2026-10-25T10:00:00Z'
    def cli(*args, ok=True):
        p = subprocess.run([sys.executable, script, *map(str, args)], text=True, capture_output=True)
        assert (p.returncode == 0) == ok, (p.returncode, p.stdout, p.stderr)
        assert secret not in p.stdout + p.stderr
        return json.loads(p.stdout) if ok else p.stderr
    def write(path, rows, mode='w'):
        with path.open(mode) as f:
            for row in rows:
                f.write(json.dumps(row) + '\n')
    def scan(specs=None):
        if specs is not None:
            manifest.write_text(json.dumps(specs))
        return cli('collect', '--manifest', manifest, '--db', db)
    def report(*args):
        return cli('summary', '--db', db, *args)
    def group(h):
        return next(g for g in report()['groups'] if g['group']['harness'] == h)
    def spec(h,p):
        return dict(harness=h, path=str(p))
    def cu(i,o,c=0):
        return dict(input_tokens=i,output_tokens=o,cached_input_tokens=c,
                    reasoning_output_tokens=o//2,total_tokens=i+o)
    def token(t,total,last):
        return dict(type='event_msg',timestamp=t,payload=dict(type='token_count',info=dict(
                    total_token_usage=total,last_token_usage=last)))
    claude, codex, pi = (root / (h+'.jsonl') for h in ('claude','codex','pi'))
    write(claude,[dict(type='assistant',sessionId='c-run',uuid='c-row',timestamp=when,
        message=dict(role='assistant',id='c-message',model='claude-fixture',
            usage=dict(input_tokens=10,output_tokens=2,cache_read_input_tokens=7,
                       cache_creation_input_tokens=3),
            content=[dict(type='text',text=secret),dict(type='tool_use',id='call-c',name='Read',
                input={'secret':secret})])),
        dict(type='user',timestamp=when,message=dict(role='user',content=[
            dict(type='tool_result',tool_use_id='call-c',content=secret,is_error=False)]))])
    write(codex,[dict(type='session_meta',payload=dict(id='x-run',cwd=secret,
        base_instructions=secret,creator_account_id=secret)),
        dict(type='turn_context',payload=dict(model='codex-fixture',turn_id='x-turn')),
        dict(type='response_item',timestamp=when,payload=dict(type='function_call',
            call_id='call-x',name='exec_command',arguments=secret)),
        token(when,cu(100,20,50),cu(100,20,50)),
        token('2026-10-25T10:00:01Z',cu(100,20,50),cu(100,20,50)),
        token('2026-10-25T10:00:02Z',cu(130,24,60),cu(30,4,10))])
    write(pi,[dict(type='session',version=3,id='p-run',cwd=secret),
        dict(type='message',id='p-user',timestamp=when,message=dict(role='user',content=secret)),
        dict(type='message',id='p-msg',timestamp=when,message=dict(role='assistant',model='pi-fixture',
            usage=dict(input=11,output=3,cacheRead=2,cacheWrite=1,totalTokens=17,
                       cost={'total':19},extra=secret),
            content=[dict(type='toolCall',id='call-p',name='bash',arguments={'command':secret})])),
        dict(type='message',id='p-result',timestamp=when,message=dict(role='toolResult',
            toolCallId='call-p',isError=True,durationMs=12,content=secret))])
    selected = [spec('claude',claude),spec('codex',codex),spec('pi',pi)]
    initial = scan(selected)
    assert initial['bytes_read'] > 0
    assert group('claude')['tokens']['input']['reported'] == 10
    assert group('claude')['tokens']['cache_read']['reported'] == 7
    assert group('claude')['tokens']['total']['unknown_records'] == 1
    assert group('claude')['tools']['Read']['status'] == {'success':1}
    assert group('codex')['usage_records'] == 2
    assert group('codex')['tokens']['input']['reported'] == 130
    assert group('codex')['tokens']['output']['reported'] == 24
    assert group('codex')['tokens']['total']['reported'] == 154
    assert group('codex')['tokens']['cache_read']['reported'] == 60
    assert group('pi')['tokens']['total']['reported'] == 17
    assert group('pi')['tools']['bash']['duration_ms'] == 12
    assert group('pi')['tools']['bash']['status'] == {'error':1}
    original = report()
    assert scan()['bytes_read'] == 0
    assert report() == original
    # Copies, renamed rotations, forks retaining original entries, and repeated scans.
    copies = []
    for h,p in [('claude',claude),('codex',codex),('pi',pi)]:
        target = root / (h+'-copy.jsonl')
        shutil.copyfile(p,target)
        copies.append(spec(h,target))
    scan(selected+copies)
    assert report()['groups'] == original['groups']
    # Real retry/request: equal per-request usage, distinct native IDs or cumulative advance.
    write(codex,[token('2026-10-25T10:00:03Z',cu(160,28,70),cu(30,4,10))],'a')
    scan(selected)
    assert group('codex')['tokens']['input']['reported'] == 160
    assert group('codex')['usage_records'] == 3
    # Claude streaming snapshots replace counters without multiplying input.
    write(claude,[dict(type='assistant',sessionId='c-run',timestamp=when,
        message=dict(role='assistant',id='c-message',model='claude-fixture',
            usage=dict(input_tokens=10,output_tokens=5)))],'a')
    scan(selected)
    assert group('claude')['tokens']['input']['reported'] == 10
    assert group('claude')['tokens']['output']['reported'] == 5
    # Partial append is held, then consumed exactly once when complete.
    partial = dict(type='message',id='p-msg-2',timestamp='2026-10-25T10:01:00Z',
        message=dict(role='assistant',usage={'input':4,'output':2},content=secret))
    raw = json.dumps(partial)
    with pi.open('a') as f: f.write(raw[:30])
    scan(selected)
    assert any('unread_bytes' in s['current'] for s in report()['sources'])
    with pi.open('a') as f: f.write(raw[30:]+'\n')
    scan(selected)
    pg = [g for g in report()['groups'] if g['group']['harness']=='pi']
    assert sum(g['tokens']['input']['reported'] for g in pg) == 15
    assert sum(g['tokens']['total']['unknown_records'] for g in pg) == 1
    # Rotation with copied content never doubles usage; missing sources disclose gaps.
    rotated = root/'pi-old.jsonl'
    pi.rename(rotated)
    shutil.copyfile(rotated,pi)
    before = report()['groups']
    scan(selected)
    assert report()['groups'] == before
    assert any('rotation_or_rewrite_rescanned' in s['gaps'] for s in report()['sources'])
    pi.unlink()
    scan(selected)
    assert any('source_missing_or_unreadable' in s['current'] for s in report()['sources'])
    # Compaction/reset retains last usage, discloses the discontinuity.
    write(codex,[token('2026-10-25T10:02:00Z',cu(5,1),cu(5,1))],'a')
    scan(selected)
    assert group('codex')['tokens']['input']['reported'] == 165
    assert any('cumulative_reset_or_compaction' in s['gaps'] for s in report()['sources'])
    # Missing initial cumulative history is not billed as the latest request.
    orphan = root/'orphan.jsonl'
    write(orphan,[dict(type='session_meta',payload={'id':'orphan'}),
                  token('2026-10-25T11:00:00Z',cu(1000,100),cu(7,1))])
    scan([spec('codex',orphan)])
    assert sum(g['tokens']['input']['reported'] for g in report()['groups']
               if g['group']['harness']=='codex') == 172
    assert any('earlier_cumulative_usage_unattributed' in s['gaps'] for s in report()['sources'])
    # Missing intermediate usage snapshots retain the delta, with unknown time/turn/model.
    write(orphan,[token('2026-10-25T11:01:00Z',cu(1020,104),cu(5,1))],'a')
    scan([spec('codex',orphan)])
    assert any('cumulative_delta_spans_unobserved_requests' in s['gaps'] for s in report()['sources'])
    assert sum(g['tokens']['input']['reported'] for g in report()['groups']
               if g['group']['harness']=='codex') == 192
    # Unknown/native-schema drift, malformed records, absent identities, no zero-cost claims.
    bad = root/'bad.jsonl'
    write(bad,[{'type':'session','version':99,'id':'future'},
               {'type':'message','id':'skip','message':{'role':'assistant','usage':{'input':1000}}}])
    with bad.open('a') as f:f.write('{broken '+secret+'}\n')
    scan([spec('pi',bad)])
    assert any('unsupported_pi_session_version' in s['gaps'] for s in report()['sources'])
    assert any('malformed_or_unknown_record' in s['gaps'] for s in report()['sources'])
    # Deterministic order, turn/tool association, time bounds, explicit labels.
    joined = root/'join.jsonl'
    write(joined,[dict(type='session',version=3,id='joined'),
        dict(type='message',id='u',timestamp=when,message={'role':'user','content':secret}),
        dict(type='message',id='a',timestamp=when,message=dict(role='assistant',model='joined-model',
            usage={'input':9,'output':1},content=[{'type':'toolCall','id':'join-call','name':'search'}]))])
    scan([{**spec('pi',joined),'project':'demo','task':'trial','task_kind':'ship','activity':'review'}])
    turns = report('--group-by','task,turn')['groups']
    assert any(g['group']['task']=='trial' and g['tool_calls']==1 and g['usage_records']==1 for g in turns)
    assert report('--since','2030-01-01T00:00:00Z')['groups'] == []
    assert report() == report()
    # Non-ledger DB and unsafe/symlink sources refused without content disclosure.
    foreign = root/'foreign.sqlite'
    with sqlite3.connect(foreign) as con:con.execute('create table unrelated (x)')
    cli('summary','--db',foreign,ok=False)
    manifest.write_text(json.dumps([spec('pi',root/'auth.json')]))
    cli('collect','--db',db,'--manifest',manifest,ok=False)
    symlink = root/'link.jsonl'
    symlink.symlink_to(joined)
    scan([spec('pi',symlink)])
    assert any('source_missing_or_unreadable' in s['current'] for s in report()['sources'])
    # Truncation/rewrite rescans retain prior observed usage and expose missing history.
    write(joined,[dict(type='session',version=3,id='joined')])
    scan([{**spec('pi',joined),'project':'demo','task':'trial','task_kind':'ship','activity':'review'}])
    assert any('rotation_or_rewrite_rescanned' in s['gaps'] for s in report()['sources'])
    # Missing tool IDs/results and invalid numeric fields remain explicitly unknown.
    unknown = root/'unknown.jsonl'
    write(unknown,[dict(type='session',version=3,id='unknown'),
        dict(type='message',id='unknown-a',timestamp=when,message=dict(role='assistant',
            usage={'input':8,'output':None,'cacheRead':-1,'cacheWrite':True},
            content=[{'type':'toolCall','name':'missing-id'},
                     {'type':'toolCall','id':'unknown-name'}])),
        dict(type='message',id='unknown-r',timestamp=when,message=dict(role='toolResult',
            toolCallId='missing-call',content=secret))])
    scan([spec('pi',unknown)])
    gaps = {g for s in report()['sources'] for g in s['gaps']}
    assert {'tool_id_unavailable','tool_result_without_call'} <= gaps
    assert any('unknown' in g['tools'] for g in report()['groups'])
    # Scan budget and oversized lines are bounded and disclosed, never treated as free.
    large = root/'large.jsonl'
    with large.open('w') as f:f.write(json.dumps({'content':'x'*(4*1024*1024+100)})+'\n')
    scan([spec('pi',large)])
    gaps = {g for s in report()['sources'] for g in s['gaps']}
    assert 'record_exceeds_4MiB_limit' in gaps
    assert any('unread_bytes' in s['current'] for s in report()['sources'])
    # Verify every persistent byte, not only the public report: raw prompts/outputs/paths excluded.
    assert secret.encode() not in db.read_bytes()
    assert str(root).encode() not in db.read_bytes()
    assert os.stat(db).st_mode & 0o077 == 0
    assert set(cli('coverage')['readers']) == {'claude','codex','pi'}
    print('PASS: native counters/cache, cumulative deltas, copies/retries/resume/reset/rotation/partial, joins, privacy, coverage')
PY
pass 'usage ledger public CLI'
