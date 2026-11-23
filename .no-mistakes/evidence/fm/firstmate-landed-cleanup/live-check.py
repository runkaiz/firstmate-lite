import os, pathlib, subprocess, time, shutil, json, sqlite3

ROOT = pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M8523ET7SQQKNK6ZPCWHTJR6')
EVIDENCE = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M8523ET7SQQKNK6ZPCWHTJR6')
BASE = ROOT / '.test-phase/live'
BASE.mkdir(parents=True, exist_ok=True)
baseline=BASE / 'baseline/bin'
shutil.copytree(ROOT / 'bin',baseline)
for name in ['fm-crew-state.sh','fm-git-worktree-lib.sh','fm-teardown.sh','fm-reconcile-underway.sh','fm-bearings-snapshot.sh','fm-branch-prompt.sh']:
    (baseline / name).write_bytes(subprocess.check_output(['git','show','e7fcba85e8d3ff657b99af74e1f407e2d6966002:bin/'+name],cwd=ROOT))
env = dict(os.environ)
for key in list(env):
    if key.startswith('FM_') or key.startswith('HERDR_') or key in ('TMUX', 'TASKS_AXI_FILE', 'TASKS_AXI_BACKEND', 'GIT_DIR', 'GIT_COMMON_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE'):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1', GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid', TMPDIR=str(ROOT / '.test-phase/tmp'))
log = open(EVIDENCE / 'live-product.log', 'w', buffering=1)

def run(args, cwd=ROOT, check=True, extra=None):
    p = subprocess.run(list(map(str,args)), cwd=cwd, env=env | (extra or {}), text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
    log.write('$ ' + ' '.join(map(str,args)) + '\n' + p.stdout + f'[exit {p.returncode}]\n')
    if check and p.returncode:
        raise RuntimeError(p.stdout)
    return p.stdout, p.returncode

def git(where, *args): return run(['git','-C',where,*args])[0].strip()
def write(path, content):
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(content)

home = BASE / 'home'
run(['bash','bin/fm-lab-home.sh','create',home])
env.update(FM_HOME=str(home), NM_HOME=str(BASE / 'nm'), TMUX=str(ROOT / '.test-phase/m/s') + ',0,0')
project = home / 'projects/demo'
project.mkdir(parents=True)
git(project,'init','-q','-b','main')
write(project / '.gitignore','/.cache/\n/build/\n__pycache__/\n/web/.next/\n/web/next-env.d.ts\n/web/node_modules/\n/web/out/\n')
write(project / 'scripts/build.py','print("build")\n')
write(project / 'web/package.json','{}\n')
git(project,'add','.')
git(project,'commit','-qm','base')
base = git(project,'rev-parse','HEAD')
write(home / 'config/backend','tmux\n')
write(home / 'config/worktree-allocator','git\n')
write(home / 'config/git-worktree-root',str(BASE / 'copies') + '\n')
write(home / 'config/backlog-backend','markdown\n')
write(home / '.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
write(home / 'data/backlog.md','# Backlog\n\n## In flight\n\n- [ ] landed - Finished work (repo: demo) (kind: ship)\n\n## Queued\n\n## Done\n')
run(['bash','-c','. "$1/bin/fm-git-worktree-lib.sh"; fm_git_worktree_allocate "$2/state" landed "$2" "$3" "$4" "$5" refs/heads/main; printf "%s\\n" "$FM_GIT_WORKTREE_PATH"','_',ROOT,home,project,BASE / 'copies',base])
reservation = dict(line.split('=',1) for line in (home / 'state/landed.git-worktree').read_text().splitlines() if '=' in line)
wt = pathlib.Path(reservation['worktree']) if 'worktree' in reservation else pathlib.Path(reservation['path'])
git(wt,'switch','-qc','fm/landed')
write(wt / 'result.txt','delivered\n')
git(wt,'add','result.txt')
git(wt,'commit','-qm','delivery')
head = git(wt,'rev-parse','HEAD')
git(project,'merge','-q','--ff-only','fm/landed')
meta = home / 'state/landed.meta'
def metadata(target='fm-lab:fm-landed', mode='local-only', extras=''):
    write(meta,f'window={target}\nendpoint_task_id=landed\nbackend=tmux\nworktree={wt}\nproject={project}\nkind=ship\nharness=claude\nspawn_gen=s1792922400.123.456\nallocator=git\nmode={mode}\nbranch=fm/landed\nbase_branch=main\n'+extras)
metadata()
generation=run(['bash','bin/fm-busy-event.sh','arm',home / 'state','landed'])[0].strip()
run(['bash','bin/fm-busy-event.sh','apply',home / 'state','landed','idle','--gen',generation,'--source','claude-hook','--event','stop'])
write(home / 'state/landed.status','done: ready in branch fm/landed\n')
tmux = ['tmux','-S',str(ROOT / '.test-phase/m/s')]
run(tmux + ['new-window','-d','-t','fm-lab','-n','fm-landed','-c',wt,'bash --noprofile --norc'])
time.sleep(.6)
def crew(): return run(['bash','bin/fm-crew-state.sh','landed'])[0].strip()
def probe(): return run(['bash','-c','. bin/fm-backend.sh; fm_backend_agent_state tmux fm-lab:fm-landed'])[0].strip()
try:
    assert probe() == 'dead'
    before=run(['bash',baseline / 'fm-crew-state.sh','landed'])[0]
    assert 'source: landed' not in before
    assert 'state: done · source: landed' in crew()
    snapshot = run(['bash','bin/fm-bearings-snapshot.sh','--json'])[0]
    write(EVIDENCE / 'bearings-landed.json',snapshot)
    obj=json.loads(snapshot)
    assert any(x['id']=='landed' and x['stage']=='finished, landed' for x in obj['in_flight'])
    assert all(x['id']!='landed' for x in obj.get('unhealthy_endpoints',[]))
    write(EVIDENCE / 'bearings-landed.txt',run(['bash','bin/fm-bearings-snapshot.sh'])[0])
    socket=ROOT / '.test-phase/m/s'
    permissions=socket.stat().st_mode & 0o777
    os.chmod(socket,0)
    try:
        assert 'backend unreachable' in crew()
    finally:
        os.chmod(socket,permissions)
    git(project,'update-ref','refs/heads/main',base)
    assert 'source: landed' not in crew()
    git(project,'update-ref','refs/heads/main',head)
    write(wt / 'result.txt','unique tracked edit\n')
    assert 'source: landed' not in crew()
    git(wt,'checkout','--','result.txt')
    write(home / 'state/landed.status','needs-decision: choose release\n')
    assert 'state: parked' in crew()
    write(home / 'state/landed.status','failed: validation failed\n')
    assert 'state: failed' in crew()
    write(home / 'state/landed.status','done: ready in branch fm/landed\n')
    (home / 'codex').mkdir()
    run(tmux + ['send-keys','-t','fm-lab:fm-landed','env CODEX_HOME='+str(home / 'codex')+' codex --no-daemon','Enter'])
    time.sleep(3)
    pane=run(tmux + ['capture-pane','-p','-t','fm-lab:fm-landed'])[0]
    write(EVIDENCE / 'codex-live-pane.txt',pane)
    assert probe() == 'alive'
    assert 'source: landed' not in crew()
    pane=run(tmux + ['capture-pane','-p','-t','fm-lab:fm-landed'])[0]
    write(EVIDENCE / 'codex-live-pane.txt',pane)
    run(tmux + ['kill-window','-t','fm-lab:fm-landed'])
    assert 'state: done · source: landed' in crew()

    # An authentic retirement record is generated by the production PR library;
    # the test represents an already observed merge and never touches a forge.
    url='https://github.com/fixture/project/pull/7'
    run(['git','clone','-q','--bare',project,BASE / 'remote.git'])
    git(project,'remote','add','origin','file://' + str(BASE / 'remote.git'))
    git(project,'fetch','-q','origin')
    metadata(mode='direct-PR',extras=f'pr={url}\npr_head={head}\n')
    run(['bash','-c','. bin/fm-pr-lib.sh; fm_pr_poll_prepare "$1/state" landed github "$2" github.com fixture/project 7 "$3/bin/fm-pr-poll.sh" && fm_pr_poll_publish_prepared && fm_pr_poll_snapshot_capture "$1/state" landed "$3/bin/fm-pr-poll.sh" && fm_pr_poll_retirement_publish "$1/state" landed "$3/bin/fm-pr-poll.sh" merged','_',home,url,ROOT])
    assert 'state: done · source: landed' in crew()
    git(wt,'commit','-q','--allow-empty','-m','after merge')
    assert 'source: landed' not in crew()
    git(wt,'reset','-q','--hard',head)
    # Exercise real no-mistakes read interfaces over disposable persisted records.
    nm=BASE / 'nm'
    nm.mkdir(exist_ok=True)
    with sqlite3.connect(ROOT / '.test-phase/nm-probe/state.sqlite') as source, sqlite3.connect(nm / 'state.sqlite') as db:
        source.backup(db)
        db.execute('INSERT INTO repos(id,working_path,upstream_url,created_at) VALUES (?,?,?,?)',('labrepo',str(project.resolve()),'file://' + str(BASE / 'remote.git'),1))
        db.execute('INSERT INTO runs(id,repo_id,branch,head_sha,base_sha,worktree_dir,status,pr_url,pr_state,created_at,updated_at) VALUES (?,?,?,?,?,?,?,?,?,?,?)',('01LABCOMPLETED0000000000000','labrepo','fm/landed',head,base,str(wt),'completed',url,'merged',1,1))
        for i,name in enumerate(['intent','review','test','lint','docs','push','pr','ci']):
            db.execute('INSERT INTO step_results(id,run_id,step_name,step_order,status,exit_code,duration_ms,findings_json) VALUES (?,?,?,?,?,?,?,?)',('step'+str(i),'01LABCOMPLETED0000000000000',name,i,'completed',0,1,'[]'))
    metadata(mode='no-mistakes',extras=f'pr={url}\npr_head={head}\n')
    write(home / 'state/landed.status','')
    run(['no-mistakes','axi','status'],cwd=wt)
    assert 'state: done · source: landed' in crew()
    with sqlite3.connect(nm / 'state.sqlite') as db: db.execute("UPDATE runs SET status='failed'")
    assert 'state: failed · source: run-step' in crew()
    with sqlite3.connect(nm / 'state.sqlite') as db: db.execute('DELETE FROM step_results'); db.execute('DELETE FROM runs'); db.execute('DELETE FROM repos')
    run(['bash','-c','. bin/fm-pr-lib.sh; fm_pr_poll_retirement_recover_one "$FM_HOME/state" landed "$PWD/bin/fm-pr-poll.sh"'])
    write(home / 'state/landed.status','done: ready in branch fm/landed\n')
    metadata()

    # One-pass native cleanup must move every generated file, including a patched clone.
    upstream=BASE / 'upstream'
    upstream.mkdir()
    git(upstream,'init','-q','-b','main')
    write(upstream / 'Engine.java','upstream source\n')
    git(upstream,'add','.')
    git(upstream,'commit','-qm','release')
    clone=wt / '.cache/CoffeeMud'
    run(['git','clone','-q',upstream,clone])
    write(clone / 'Engine.java','patched source\n')
    write(clone / 'Engine.class','compiled\n')
    files={'.cache/jdk/bin/java':'java\n','build/app.o':'object\n','scripts/__pycache__/build.pyc':'bytecode\n','web/.next/page':'page\n','web/next-env.d.ts':'types\n','web/node_modules/pkg/index.js':'module\n','web/out/index.html':'page\n'}
    for name, data in files.items(): write(wt / name,data)
    # Unique nested history must prevent automatic cleanup and preserve all resources.
    write(clone / 'own.txt','unique work\n')
    git(clone,'add','own.txt')
    git(clone,'commit','-qm','unpublished')
    out,rc=run(['bash','bin/fm-teardown.sh','landed'],check=False)
    assert rc != 0 and '--preserve-untracked' in out and wt.is_dir() and meta.is_file()
    git(clone,'reset','-q','--hard','HEAD~1')
    out,rc=run(['bash','bin/fm-teardown.sh','landed'],check=False)
    assert rc != 0 and wt.is_dir() # reflog alone still protects unique work
    shutil.rmtree(clone)
    run(['git','clone','-q',upstream,clone])
    write(clone / 'Engine.java','patched source\n')
    write(clone / 'Engine.class','compiled\n')
    before,rc=run(['bash',baseline / 'fm-teardown.sh','landed'],check=False)
    assert rc != 0 and '--preserve-untracked' in before and wt.is_dir()
    out,rc=run(['bash','bin/fm-teardown.sh','landed'])
    assert not wt.exists() and not meta.exists()
    kept=home / 'data/landed/preserved-artifacts/files'
    for name,data in files.items(): assert (kept / name).read_text()==data
    assert (kept / '.cache/CoffeeMud/Engine.java').read_text()=='patched source\n'
    assert (kept / '.cache/CoffeeMud/Engine.class').read_text()=='compiled\n'
    git(kept / '.cache/CoffeeMud','rev-parse','HEAD')
    manifest=run(['bash','bin/fm-queue.sh','show','landed'])[0]
    assert 'state: done' in manifest
    write(EVIDENCE / 'preserved-files.json',json.dumps({str(p.relative_to(kept)):p.read_text() for p in kept.rglob('*') if p.is_file() and '.git' not in p.parts},indent=2))
    log.write('ALL LIVE PRODUCT ASSERTIONS PASSED\n')
finally:
    run(tmux + ['kill-server'],check=False)
    shutil.rmtree(BASE)
    log.close()
