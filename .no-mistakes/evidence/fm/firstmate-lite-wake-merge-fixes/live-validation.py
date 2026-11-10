import os, pathlib, subprocess, tempfile, time, shutil, json, shlex, sys

ROOT = pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73GCD8YSB63KQGNTDA6EY1T')
EVIDENCE = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73GCD8YSB63KQGNTDA6EY1T')
TMP = ROOT / '.test-phase-tmp'
BASE_ENV = {k:v for k,v in os.environ.items() if not k.startswith(('FM_', 'TASKS_AXI_', 'GIT_CONFIG_')) and k not in ('TMUX', 'TMUX_PANE')}
BASE_ENV.update(TMPDIR=str(TMP), GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_SYSTEM='/dev/null', GIT_AUTHOR_NAME='Lab', GIT_AUTHOR_EMAIL='lab@example.invalid', GIT_COMMITTER_NAME='Lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
results = []

def wait_for(predicate, seconds=30):
    until = time.monotonic() + seconds
    while time.monotonic() < until:
        if predicate(): return
        time.sleep(.1)
    raise AssertionError('Timed out waiting for product state')

def read(path):
    return pathlib.Path(path).read_text() if pathlib.Path(path).exists() else ''

class Lab:
    def __init__(self, name):
        self.path = pathlib.Path(tempfile.mkdtemp(prefix='fm-lab-'+name+'-', dir=TMP))
        self.home = self.path / 'home'
        self.env = dict(BASE_ENV, FM_HOME=str(self.home), FM_PROCEVENT_CLAIM_ROOT=str(self.path/'claims'), TMUX=str(self.path/'absent-socket')+',0,0')
        self.log = open(EVIDENCE/(name+'-live.log'), 'w', buffering=1)
        self.processes = []
        self.socket = None
        self.run('bin/fm-lab-home.sh', 'create', str(self.home))
    def note(self, text):
        self.log.write(text+'\n')
    def run(self, *args, ok=True, env=None):
        args = [str(a) for a in args]
        self.note('$ ' + ' '.join(args))
        p = subprocess.run(args, cwd=ROOT, env=env or self.env, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
        self.note(p.stdout + '[exit '+str(p.returncode)+']')
        if ok: assert p.returncode == 0, p.stdout
        return p
    def start(self, *args, name, env=None):
        output = open(self.path/(name+'.out'), 'w')
        p = subprocess.Popen([str(a) for a in args], cwd=ROOT, env=env or self.env, text=True, stdout=output, stderr=subprocess.STDOUT)
        self.processes.append((p, output))
        return p, self.path/(name+'.out')
    def append(self, key, text):
        self.run('bash', '-c', '. "$1/bin/fm-wake-lib.sh"; fm_wake_append check "$2" "$3"', '_', ROOT, key, text)
    def ack(self, output):
        line = next(x for x in output.splitlines() if x.startswith('WAKE_ACK_REQUIRED:'))
        self.run(*shlex.split(line.split(' run ', 1)[1]))
    def close(self):
        try:
            self.run('bin/fm-procevent.sh', 'sweep-home', ok=False)
            self.run('bin/fm-watch-arm.sh', '--stop', ok=False)
            if self.socket:
                self.run('tmux', '-S', self.socket, 'kill-server', ok=False)
                self.socket.unlink(missing_ok=True)
        finally:
            for p,f in self.processes:
                if p.poll() is None: p.terminate()
                try: p.wait(timeout=10)
                except subprocess.TimeoutExpired: p.kill(); p.wait()
                f.close()
            self.note('Disposable home, project, copies and process claims removed.')
            self.log.close()
            shutil.rmtree(self.path)

def monitoring():
    lab = Lab('monitoring')
    try:
        lab.env.update(FM_POLL='1', FM_SIGNAL_GRACE='0', FM_CHECK_INTERVAL='999999', FM_HEARTBEAT='999999')
        state = lab.home/'state'
        first, out = lab.start('bin/fm-watch-arm.sh', name='first')
        wait_for(lambda: 'watcher: started ' in read(out))
        lab.run('bin/fm-watch-arm.sh', '--stop')
        first.wait(timeout=30)
        lab.note('Initial stop:\n'+read(out))
        assert read(state/'.watcher-down').startswith('pending:downtime:')
        arm, out = lab.start('bin/fm-watch-arm.sh', name='empty-rearm')
        wait_for(lambda: read(state/'.watcher-down').startswith('acked:downtime:'))
        time.sleep(2)
        assert arm.poll() is None
        assert not read(state/'.wake-queue')
        assert 'resurface:' not in read(out)
        lab.note('Empty restart stays armed with no queued wake; marker='+read(state/'.watcher-down'))
        lab.append('lab-action', 'check: an actionable lab event arrived')
        arm.wait(timeout=30)
        lab.note('Action after silent restart:\n'+read(out))
        assert 'check:' in read(out)
        q = read(state/'.wake-queue'); lab.note('Durable queue:\n'+q)
        drain = lab.run('bin/fm-wake-drain.sh').stdout
        assert 'an actionable lab event arrived' in drain
        lab.ack(drain)
        # Adversarial gap: queue real work while no watcher owns the home.
        lab.append('lab-gap-action', 'check: actionable event queued during downtime')
        arm, out = lab.start('bin/fm-watch-arm.sh', name='queued-rearm')
        arm.wait(timeout=30)
        lab.note('Restart with queued work:\n'+read(out))
        assert 'resurface' in read(out) or 'lab-gap-action' in read(out)
        drain = lab.run('bin/fm-wake-drain.sh').stdout
        assert 'actionable event queued during downtime' in drain
        results.append(dict(name='Silent empty re-arm, later action, and queued-during-gap recovery', result='pass', live=True, evidence='monitoring-live.log', reason=''))
    finally: lab.close()

def replay():
    lab = Lab('replay')
    try:
        state = lab.home/'state'
        for name in ('branch', 'main'):
            lab.run('bin/fm-procevent-when.sh', 'arm', name, '--interval', '0.1', '--stable', '1', '--condition', '/usr/bin/test', '-d', str(lab.home), '--action', '/usr/bin/printf', '%s', name+' completed')
            runner, runner_out = lab.start('bin/fm-procevent.sh', 'start', 'when-'+name, name='runner-'+name)
            runner.wait(timeout=30)
            lab.note('Runner '+name+':\n'+read(runner_out))
            assert runner.returncode == 0
        wait_for(lambda: len(list((state/'procevent-inbox').glob('*.result'))) == 2 and len(read(state/'.wake-queue').splitlines()) >= 2)
        original = read(state/'.wake-queue')
        lab.note('Original captures:\n'+original)
        for capture in (state/'procevent-inbox').glob('*.result'):
            lab.note(capture.name+'\n'+capture.read_text())
        lab.ack(lab.run('bin/fm-wake-drain.sh').stdout)
        lab.run('bin/fm-procevent.sh', 'reconcile')
        replay_rows = read(state/'.wake-queue')
        assert 'procevent:when-branch:1' in replay_rows and 'procevent:when-main:1' in replay_rows
        lab.note('Replays published BEFORE handling:\n'+replay_rows)
        for name in ('branch', 'main'):
            assert 'handled:' in lab.run('bin/fm-procevent.sh', 'handled', 'when-'+name, '1').stdout
        lab.append('lab-unrelated', 'check: unrelated lab event remains actionable')
        rows = [x.split('\t') for x in read(state/'.wake-queue').splitlines()]
        branch_seq = next(x[1] for x in rows if x[3]=='procevent:when-branch:1')
        unrelated_seq = next(x[1] for x in rows if x[3]=='lab-unrelated')
        lab.run('bin/fm-wake-grant.sh', 'activate', str(os.getpid()), 'live-replay')
        lab.run('bin/fm-wake-grant.sh', 'publish', 'live-replay', branch_seq, unrelated_seq)
        branch_env = dict(lab.env, FM_SUPERVISION_ACTOR='branch')
        out = lab.run('bin/fm-wake-drain.sh', env=branch_env).stdout
        assert 'procevent when' not in out and 'PROCEVENT_HANDLED_REQUIRED' not in out
        assert 'unrelated lab event remains actionable' in out
        remaining = read(state/'.wake-queue'); lab.note('Queue after branch drain:\n'+remaining)
        assert 'procevent:when-main:1' in remaining and 'procevent:when-branch:1' not in remaining
        lab.run('bin/fm-wake-grant.sh', 'deactivate', str(os.getpid()), 'live-replay')
        out = lab.run('bin/fm-wake-drain.sh').stdout
        assert 'procevent when' not in out and 'PROCEVENT_HANDLED_REQUIRED' not in out
        assert 'unrelated lab event remains actionable' in out
        assert 'procevent:' not in read(state/'.wake-queue')
        assert 'already-handled:' in lab.run('bin/fm-procevent.sh', 'handled', 'when-main', '1').stdout
        results.append(dict(name='Handled replays disappear for main and branch while branch preserves ungranted rows', result='pass', live=True, evidence='replay-live.log', reason=''))
    finally: lab.close()

def landing():
    lab = Lab('retained-landing')
    try:
        home, state = lab.home, lab.home/'state'
        lab.socket = ROOT/'.fl.sock'
        assert not lab.socket.exists()
        lab.run('tmux', '-S', lab.socket, '-f', '/dev/null', 'new-session', '-d', '-s', 'lab', '-n', 'main', '-x', '120', '-y', '40', 'bash --noprofile --norc')
        lab.env['TMUX'] = str(lab.socket)+',0,0'
        project, copies = lab.path/'project', lab.path/'copies'
        lab.run('git', 'init', '-q', '-b', 'main', project)
        lab.run('git', '-C', project, 'commit', '-qm', 'base', '--allow-empty')
        base = lab.run('git', '-C', project, 'rev-parse', 'HEAD').stdout.strip()
        (home/'config/backlog-backend').write_text('manual\n')
        (home/'config/worktree-allocator').write_text('git\n')
        (home/'config/git-worktree-root').write_text(str(copies)+'\n')
        allocated = lab.run('bash', '-c', '. "$1/bin/fm-git-worktree-lib.sh"; fm_git_worktree_allocate "$FM_HOME/state" retained "$FM_HOME" "$2" "$3" "$4" refs/heads/main && printf "%s\\n" "$FM_GIT_WORKTREE_PATH"', '_', ROOT, project, copies, base).stdout
        wt = pathlib.Path(allocated.strip().splitlines()[-1])
        lab.run('git', '-C', wt, 'switch', '-qc', 'fm/retained')
        (wt/'delivered.txt').write_text('retained task work\n')
        lab.run('git', '-C', wt, 'add', 'delivered.txt')
        lab.run('git', '-C', wt, 'commit', '-qm', 'delivery')
        head = lab.run('git', '-C', wt, 'rev-parse', 'HEAD').stdout.strip()
        (state/'retained.meta').write_text(f'window=lab:fm-retained\nendpoint_task_id=retained\nspawn_gen=s1792922400.123.456\nbackend=tmux\nworktree={wt}\nproject={project}\nkind=ship\nmode=local-only\nbranch=fm/retained\nallocator=git\n')
        os.chmod(state/'retained.meta', 0o600)
        out = lab.run('bin/fm-teardown.sh', 'retained', ok=False)
        assert out.returncode != 0 and wt.exists()
        lab.run('bin/fm-teardown.sh', 'retained', '--retain-branch')
        assert not wt.exists() and not (state/'retained.meta').exists()
        lab.note('Retained landing record:\n'+read(state/'retained.retained'))
        assert lab.run('git', '-C', project, 'rev-parse', 'refs/firstmate/retained-work/retained').stdout.strip() == head
        assert lab.run('git', '-C', project, 'rev-parse', 'main').stdout.strip() == base
        (project/'dirty').write_text('must not be discarded\n')
        refused = lab.run('bin/fm-merge-local.sh', 'retained', ok=False)
        assert refused.returncode != 0 and 'dirty working tree' in refused.stdout and (state/'retained.retained').exists()
        (project/'dirty').unlink()
        lab.run('bin/fm-merge-local.sh', 'retained')
        assert lab.run('git', '-C', project, 'rev-parse', 'main').stdout.strip() == head
        assert read(project/'delivered.txt') == 'retained task work\n'
        assert not (state/'retained.retained').exists()
        refused = lab.run('bin/fm-merge-local.sh', 'retained', ok=False)
        assert refused.returncode != 0 and 'no meta for task' in refused.stdout
        results.append(dict(name='Retain an unlanded branch, reject dirty landing, then fast-forward after cleanup', result='pass', live=True, evidence='retained-landing-live.log', reason=''))
    finally: lab.close()

selected = (monitoring, replay, landing)
if len(sys.argv) > 1:
    selected = tuple(x for x in selected if x.__name__ in sys.argv[1:])
    results = [x for x in json.loads((EVIDENCE/'live-results.json').read_text()) if x['result'] == 'pass']
for scenario in selected:
    try: scenario()
    except Exception as e:
        results.append(dict(name=scenario.__name__, result='fail', live=True, evidence='See corresponding live log', reason=repr(e)))
        print(scenario.__name__, 'FAIL', repr(e), flush=True)
    else: print(scenario.__name__, 'PASS', flush=True)
(EVIDENCE/'live-results.json').write_text(json.dumps(results, indent=2)+'\n')
