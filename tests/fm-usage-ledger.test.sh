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

# Automatic lifecycle attachment uses only scoped native metadata and private state.
python3 - "$ROOT" <<'PY'
import fcntl
import json
import os
from pathlib import Path
import sqlite3
import subprocess
import sys
import tempfile
import time

repo = Path(sys.argv[1])
auto = repo / "bin/fm-usage-auto.py"
ledger = repo / "bin/fm-usage-ledger.py"
secret = "DO_NOT_PERSIST_PROMPT_TOOL_ARGS_729846"
with tempfile.TemporaryDirectory(prefix="fm-usage-auto-test-") as tmp:
    root = Path(tmp)
    home = root / "home"
    for part in ("state", "data", "config"):
        (home / part).mkdir(parents=True)
    codex, claude, pi, nm = [root / n for n in ("codex", "claude", "pi", "nm")]
    for d in (codex, claude, pi, nm): d.mkdir()
    env = dict(os.environ, FM_HOME=str(home), CODEX_HOME=str(codex), CLAUDE_CONFIG_DIR=str(claude),
               PI_CODING_AGENT_DIR=str(pi), NM_HOME=str(nm))
    for key in ("FM_DATA_OVERRIDE", "FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE"):env.pop(key, None)
    store = home / "data/usage-ledger"
    index = sqlite3.connect(codex / "state_5.sqlite")
    index.execute("create table threads (id text primary key, rollout_path text, cwd text)")
    index.commit()
    pipeline = sqlite3.connect(nm / "state.sqlite")
    pipeline.executescript("create table repos(id text, working_path text); "
                          "create table runs(id text, repo_id text, branch text, created_at integer, worktree_dir text);")
    project, worktree, validation = root / "project", root / "worker", root / "validation"
    start = 1792922400  # 2026-10-25T10:00:00Z
    meta = home / "state/job.meta"
    def metadata(g, h="codex"):
        meta.write_text(f"spawn_gen=s{g}.123.456\nworktree={worktree}\nharness={h}\nkind=ship\n"
                        f"branch=fm/job\nproject={project}\naccount={secret}\n")
    metadata(start)
    pipeline.execute("insert into repos values (?,?)", ("p", str(project)))
    pipeline.execute("insert into runs values (?,?,?,?,?)", ("r", "p", "fm/job", start, str(validation)))
    pipeline.commit()
    def write(path, rows, mode="w"):
        path.parent.mkdir(parents=True, exist_ok=True)
        with path.open(mode) as out:
            for row in rows:out.write(json.dumps(row) + "\n")
    def command(*args, ok=True):
        p = subprocess.run([sys.executable, str(auto), *map(str,args)], env=env, capture_output=True, text=True)
        assert (p.returncode == 0) == ok, (p.returncode,p.stdout,p.stderr)
        assert secret not in p.stdout+p.stderr
        return json.loads(p.stdout) if p.stdout else None
    def refresh(*args):return command("refresh", "--force", *args)
    def report():
        p = subprocess.run([sys.executable,str(ledger),"summary","--db",str(store/"usage.sqlite")],
                           capture_output=True,text=True,check=True)
        return json.loads(p.stdout)
    def total():return sum(g["tokens"]["input"]["reported"] for g in report()["groups"])
    def cx(name, cwd, when, amount=7):
        path = root / "logs" / (name + ".jsonl")
        write(path,[dict(type="session_meta",payload=dict(id=name,cwd=str(cwd),timestamp=when)),
                    dict(type="turn_context",payload=dict(model="test-model",turn_id=name)),
                    dict(type="response_item",timestamp=when,payload=dict(type="function_call",call_id=name,
                         name="PRIVATE_TOOL_NAME",arguments=secret)),
                    dict(type="event_msg",timestamp=when,payload=dict(type="token_count",info=dict(
                         total_token_usage=dict(input_tokens=amount,output_tokens=2),
                         last_token_usage=dict(input_tokens=amount,output_tokens=2))))])
        index.execute("insert into threads values (?,?,?)", (name,str(path),str(cwd)));index.commit()
        return path
    cx("old",worktree,"2026-10-24T10:00:00Z",900)
    cx("worker",worktree,"2026-10-25T10:00:01Z")
    cx("supervisor",home,"2026-10-25T10:00:02Z",11)
    cx("foreign",root/"foreign","2026-10-25T10:00:03Z",1000)
    cx("validation",validation,"2026-10-25T10:00:04Z",13)
    first = refresh("--remember","job")
    assert first["enabled"] and first["known_sources"] == 3,first
    assert total() == 31,report()
    assert {g["group"]["task"] for g in report()["groups"]} == {"job","firstmate"}
    assert refresh()["bytes_read"] == 0
    # Newly created sessions are found without editing any manifest.
    cx("new",worktree,"2026-10-25T10:00:05Z",17)
    assert refresh()["known_sources"] == 4
    assert total() == 48
    # Partial tail is held until complete, then included exactly once.
    path = root/"logs/new.jsonl"
    entry = dict(type="event_msg",timestamp="2026-10-25T10:00:06Z",payload=dict(type="token_count",info=dict(
        total_token_usage=dict(input_tokens=20,output_tokens=3),last_token_usage=dict(input_tokens=3,output_tokens=1))))
    with path.open("a") as out:out.write(json.dumps(entry))
    assert "unread_bytes" in refresh()["gaps"]
    assert total() == 48
    with path.open("a") as out:out.write("\n")
    refresh();assert total() == 51
    # A cleanup handoff is durable even with an overlapping collector lock.
    with (store/".lock").open("w") as lock:
        fcntl.flock(lock,fcntl.LOCK_EX)
        assert refresh("--retire","job")["deferred"] == "overlapping_refresh"
        assert list((store/"pending").glob("*.json"))
        meta.unlink()
    refresh()
    assert any(g["group"]["task"] == "job" for g in report()["groups"])
    assert json.loads((store/"catalog.json").read_text())["generations"]
    # Reused paths exclude sessions older than the new generation.
    metadata(start+100, "codex")
    cx("relaunch",worktree,"2026-10-25T10:02:00Z",19)
    refresh("--remember","job");assert total() == 70
    # Native Pi store uses exact cwd header, not the encoded directory alone.
    import re
    pd = pi/"sessions"/("--"+re.sub(r"[/\\:]","-",str(home).lstrip("/\\"))+"--")
    ph = dict(type="session",version=3,id="pi-supervisor",cwd=str(home),timestamp="2026-10-25T10:00:00Z")
    usage = dict(input=2,output=1,cacheRead=3,totalTokens=6)
    msg = dict(type="message",id="pm",timestamp="2026-10-25T10:00:07Z",message=dict(role="assistant",
        model="pi-model",usage=usage,content=[dict(type="text",text=secret)]))
    write(pd/"one.jsonl",[ph,msg])
    refresh();assert total() == 72
    write(pd/"two.jsonl",[dict(ph,id="pi-next"),dict(msg,id="pn",timestamp="2026-10-25T10:00:08Z")])
    refresh();assert total() == 74
    write(pd/"foreign.jsonl",[dict(ph,cwd=str(root/"unrelated")),dict(msg,id="pf")])
    refresh();assert total() == 74
    # Unsupported/partial headers are retried without needing a directory change.
    partial = pd/"partial.jsonl"
    partial.write_text(json.dumps(dict(ph,id="partial")))
    assert "native_metadata_unavailable" in refresh()["gaps"]
    with partial.open("a") as out:out.write("\n"+json.dumps(dict(msg,id="partial-msg"))+"\n")
    refresh();assert total() == 76
    # Auxiliary and nested usage have their own native identities and unknown models.
    write(pd/"one.jsonl",[
        dict(type="usage",id="warm",timestamp="2026-10-25T10:00:09Z",kind="cache_warm",model="pi-model",usage=usage),
        dict(type="compaction",id="compact",timestamp="2026-10-25T10:00:10Z",usage=usage,summary=secret),
        dict(type="message",id="nested",timestamp="2026-10-25T10:00:11Z",message=dict(role="toolResult",usage=usage,content=secret))],"a")
    refresh();assert total() == 82
    assert any(g["group"]["model"] is None for g in report()["groups"])
    # Bounded discovery continues across pages; source scans rotate fairly.
    for i in range(40):cx(f"bulk-{i:03}",worktree,f"2026-10-25T10:03:{i:02}Z",1)
    for _ in range(80):
        refresh("--max-candidates","7")
        if total() == 122:break
    assert total() == 122,total()
    # Claude prelude records do not prevent native session metadata discovery.
    cd = claude/"projects"/re.sub(r"[^a-zA-Z0-9]","-",str(home))
    write(cd/"claude.jsonl",[dict(type="file-history-snapshot",snapshot={"text":secret}),
        dict(type="assistant",sessionId="claude-native",cwd=str(home),timestamp="2026-10-25T10:05:00Z",
             message=dict(role="assistant",id="claude-message",model="claude-test",
                          usage=dict(input_tokens=5,output_tokens=2),content=secret))])
    refresh();assert total() == 127
    # Persistent partial headers cannot starve later completed metadata retries.
    for i in range(35):
        (pd/f"retry-{i:03}.jsonl").write_text(json.dumps(dict(ph,id=f"retry-{i}")))
    for _ in range(4):refresh()
    completed = pd/"retry-034.jsonl"
    with completed.open("a") as out:
        out.write("\n"+json.dumps(dict(msg,id="retry-completed"))+"\n")
    for _ in range(4):
        retry_result = refresh()
        if total() == 129:break
    assert total() == 129,total()
    assert "native_metadata_unavailable" in retry_result["gaps"]
    assert "metadata_retry_backlog" in retry_result["gaps"]
    # Replaced files cannot adopt a foreign session under an old source join.
    original = (cd/"claude.jsonl").read_text()
    write(cd/"claude.jsonl",[dict(type="assistant",sessionId="foreign-native",cwd=str(root/"foreign"),
        timestamp="2026-10-25T10:05:00Z",message=dict(role="assistant",id="foreign-msg",
            model="claude-test",usage=dict(input_tokens=900),content=secret))])
    assert "source_metadata_changed_or_unavailable" in refresh()["gaps"]
    assert total() == 129
    (cd/"claude.jsonl").write_text(original)
    refresh();assert total() == 129
    # Actual overlapping subprocesses either defer or serialize their offsets.
    commands = [[sys.executable,str(auto),"refresh","--force"] for _ in range(2)]
    children = [subprocess.Popen(c,env=env,stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True) for c in commands]
    for child in children:
        stdout,stderr=child.communicate(timeout=10)
        assert child.returncode == 0,(stdout,stderr)
    assert total() == 129
    # A failed collection reports unknown coverage, without changing a foreign DB.
    foreign = root/"foreign-store"
    foreign.mkdir(mode=0o700)
    with sqlite3.connect(foreign/"usage.sqlite") as f:f.execute("create table unrelated (secret text)")
    result=command("refresh","--force","--store",foreign,ok=False)
    assert "automatic_refresh_failed_or_deadline" in result["gaps"]
    assert command("status","--store",foreign)["gaps"] == result["gaps"]
    # Explicit disable leaves the old ledger unchanged and reports unknown coverage.
    flag = home/"config/usage-ledger"
    flag.write_text("off\n")
    previous = (store/"usage.sqlite").read_bytes()
    assert not refresh()["enabled"]
    assert (store/"usage.sqlite").read_bytes() == previous
    flag.unlink()
    metadata(start+200,"opencode")
    assert "unsupported_worker_reader_opencode" in refresh()["gaps"]
    # Failed native index is a visible gap; it never creates a replacement index.
    index.close();(codex/"state_5.sqlite").unlink()
    assert "codex_native_index_unavailable" in refresh()["gaps"]
    assert not (codex/"state_5.sqlite").exists()
    # Privacy covers catalog/index/status and persistent DB, not just summaries.
    for f in store.rglob("*"):
        assert f.stat().st_mode & 0o077 == 0,(f,oct(f.stat().st_mode))
        if f.is_file():
            assert secret.encode() not in f.read_bytes(),f
            assert b"PRIVATE_TOOL_NAME" not in f.read_bytes(),f
    print("PASS: automatic defaults, exact discovery, future sessions, generation handoff, overlapping refresh, partial tail, pipeline copies, bounded continuation, auxiliary usage, disable, failures, privacy")
PY
pass 'automatic native usage lifecycle'

# Suites sourcing tests/lib.sh keep default-on lifecycle collection enabled but
# confined to the library's synthetic native roots, never the ambient defaults.
USAGE_ROOTS_TMP=$(fm_test_tmproot fm-usage-roots) || fail 'could not create usage-roots fixture'
python3 - "$ROOT" "$USAGE_ROOTS_TMP" <<'PY' || fail 'synthetic suites discovered ambient native usage roots'
import json, os, re, sqlite3, subprocess, sys, time
from pathlib import Path

repo, root = Path(sys.argv[1]), Path(sys.argv[2])
synthetic = {v: Path(os.environ[v]) for v in ("CODEX_HOME", "CLAUDE_CONFIG_DIR", "PI_CODING_AGENT_DIR", "NM_HOME")}
ambient = root / "ambient-home"  # stands in for the operator's real default roots
for v, path in synthetic.items():
    assert path.is_absolute() and path.is_dir() and not any(path.iterdir()), (v, path)
    assert not path.is_relative_to(ambient), (v, path)
home, start = root / "home", int(time.time()) - 60
for part in ("state", "data", "config"):
    (home / part).mkdir(parents=True)
when = time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(start + 1))

def jsonl(path, rows):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("".join(json.dumps(r) + "\n" for r in rows))

def claude_session(directory, cwd):
    jsonl(directory / (re.sub(r"[^a-zA-Z0-9]", "-", cwd) + "/s.jsonl"),
          [dict(type="assistant", sessionId="c-" + Path(cwd).name, cwd=cwd, timestamp=when,
                message=dict(role="assistant", id="m", model="fixture",
                             usage=dict(input_tokens=5, output_tokens=1)))])

workers = {h: root / ("worker-" + h) for h in ("claude", "codex", "pi")}
for h, cwd in workers.items():
    (home / f"state/job-{h}.meta").write_text(
        f"spawn_gen=s{start}.1.1\nworktree={cwd}\nharness={h}\nkind=ship\n"
        f"branch=fm/job-{h}\nproject={root / 'project'}\n")
# Matching native sessions exist only under the ambient default roots.
claude_session(ambient / ".claude/projects", str(workers["claude"]))
pi_cwd = str(workers["pi"])
jsonl(ambient / ".pi/agent/sessions" / ("--" + re.sub(r"[/\\:]", "-", pi_cwd.lstrip("/")) + "--") / "s.jsonl",
      [dict(type="session", version=3, id="p", cwd=pi_cwd, timestamp=when)])
rollout = ambient / ".codex/sessions/x.jsonl"
jsonl(rollout, [dict(type="session_meta", payload=dict(id="x", cwd=str(workers["codex"]), timestamp=when))])
index = sqlite3.connect(ambient / ".codex/state_5.sqlite")
index.execute("create table threads (id text primary key, rollout_path text, cwd text)")
index.execute("insert into threads values ('x', ?, ?)", (str(rollout), str(workers["codex"])))
index.commit()
(ambient / ".no-mistakes").mkdir()
nm = sqlite3.connect(ambient / ".no-mistakes/state.sqlite")
nm.executescript("create table repos(id text, working_path text); "
                 "create table runs(id text, repo_id text, branch text, created_at integer, worktree_dir text);")
nm.execute("insert into repos values ('p', ?)", (str(root / "project"),))
nm.execute("insert into runs values ('r', 'p', 'fm/job-codex', ?, ?)", (start, str(workers["claude"])))
nm.commit()

env = dict(os.environ, HOME=str(ambient), FM_HOME=str(home))
for key in ("FM_DATA_OVERRIDE", "FM_STATE_OVERRIDE", "FM_CONFIG_OVERRIDE"):
    env.pop(key, None)
def lifecycle_refresh():
    subprocess.run([str(repo / "bin/fm-usage-refresh.sh"), "--force"], env=env, check=True)
    out = subprocess.run([sys.executable, str(repo / "bin/fm-usage-auto.py"), "status"],
                         env=env, check=True, capture_output=True, text=True).stdout
    return json.loads(out)

status = lifecycle_refresh()
assert status["enabled"] and status["known_sources"] == 0, status
assert "no_native_sources_observed_usage_unknown" in status["gaps"], status
# The same enabled collection still discovers sessions in the synthetic roots.
claude_session(synthetic["CLAUDE_CONFIG_DIR"] / "projects", str(workers["claude"]))
status = lifecycle_refresh()
assert status["enabled"] and status["known_sources"] == 1, status
PY
pass 'suite fixtures confine default-on usage collection to synthetic native roots'
