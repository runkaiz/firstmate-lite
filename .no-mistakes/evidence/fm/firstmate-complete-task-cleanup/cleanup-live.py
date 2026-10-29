import os, pathlib, subprocess, tempfile, time, shutil, json, re

ROOT = pathlib.Path(os.environ.get('VALIDATION_SOURCE', '/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M64TZWBQA10NCA1ZZX5VRMAT'))
EVIDENCE = pathlib.Path('/home/runkai/.no-mistakes/evidence/01M64TZWBQA10NCA1ZZX5VRMAT')
LAB = pathlib.Path(tempfile.mkdtemp(prefix='.cleanup-lab-', dir=ROOT))
HOME = LAB / 'home'
env = dict(os.environ)
for key in list(env):
    if (key.startswith('FM_') or key.startswith('TASKS_AXI_') or
            key in ['TMUX', 'NO_MISTAKES_GATE']):
        del env[key]
env.update(FM_HOME=str(HOME), GIT_CONFIG_NOSYSTEM='1', GIT_CONFIG_GLOBAL='/dev/null',
           GIT_AUTHOR_NAME='Lifecycle Lab', GIT_AUTHOR_EMAIL='lab@example.invalid',
           GIT_COMMITTER_NAME='Lifecycle Lab', GIT_COMMITTER_EMAIL='lab@example.invalid')
log = (EVIDENCE / 'live-lifecycle.log').open('w', buffering=1)
watchers = []
socket_dir = None

def run(*args, expect=0, quiet=False, cwd=None):
    result = subprocess.run([str(x) for x in args], env=env, cwd=cwd or ROOT,
                            text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT, timeout=60)
    if not quiet:
        log.write('$ ' + ' '.join(str(x) for x in args) + '\n' + result.stdout + f'[exit {result.returncode}]\n')
    if expect is not None:
        assert result.returncode == expect, result.stdout
    return result

def tmux(*args, **kw):
    return run('tmux', '-L', 'fm-lab', *args, **kw)

def git(path, *args):
    return run('git', '-C', path, *args, quiet=True).stdout.strip()

def snapshot(id):
    meta = HOME / 'state' / (id + '.meta')
    wt = LAB / 'copies' / id / 'worktree'
    state = dict(copy_exists=wt.exists(), meta_exists=meta.exists(),
                 reservation_exists=(HOME/'state'/(id+'.git-worktree')).exists(),
                 windows=tmux('list-windows', '-t', 'firstmate', '-F', '#{window_name}', quiet=True).stdout.splitlines())
    log.write('RESOURCE STATE '+id+' '+json.dumps(state)+'\n')
    return state

def spawn(id, scout=False):
    data = HOME / 'data' / id
    data.mkdir()
    (data/'brief.md').write_text('# Task\n## Captain\'s intent\nExercise disposable cleanup.\n\n## Firstmate spec\nObserve lifecycle.\n')
    (HOME/'state'/'.last-watcher-beat').touch()
    cmd = ['bash', 'bin/fm-spawn.sh', id, str(LAB/'project'), 'sleep 2', '--backend', 'tmux']
    if scout:
        cmd += ['--scout']
    else:
        cmd += ['--mode', 'local-only', '--yolo', 'off']
    run(*cmd)
    time.sleep(3)
    return LAB/'copies'/id/'worktree'

def teardown(id, ok=True):
    (HOME/'state'/'.last-watcher-beat').touch()
    rc = run('bash', 'bin/fm-teardown.sh', id, expect=None).returncode
    assert (rc == 0) == ok, (id, rc)
    state = snapshot(id)
    if ok:
        assert not state['copy_exists'] and not state['meta_exists'] and not state['reservation_exists']
        assert 'fm-'+id not in state['windows']
    else:
        assert state['copy_exists'] and state['meta_exists'] and 'fm-'+id in state['windows']

try:
    run('bash', 'bin/fm-lab-home.sh', 'create', HOME)
    socket_dir = run('bash', 'bin/fm-lab-home.sh', 'tmux-dir', HOME).stdout.strip()
    env['TMUX_TMPDIR'] = socket_dir
    env['TMUX'] = socket_dir + '/tmux-' + str(os.getuid()) + '/fm-lab,0,0'
    for key, value in {'worktree-allocator':'git', 'git-worktree-root':str(LAB/'copies'),
                       'backlog-backend':'manual', 'usage-ledger':'off', 'crew-harness':'codex'}.items():
        (HOME/'config'/key).write_text(value+'\n')
    (HOME/'data'/'projects.md').write_text('- project [local-only]\n')
    project = LAB/'project'
    project.mkdir()
    git(project, 'init', '-b', 'main')
    (project/'file').write_text('initial\n')
    (project/'.gitignore').write_text('.session/\n')
    git(project, 'add', '.')
    git(project, 'commit', '-m', 'initial')
    tmux('-f', '/dev/null', 'new-session', '-d', '-s', 'firstmate', '-n', 'main', '-x', '120', '-y', '40', '-c', ROOT, '/bin/bash --noprofile --norc')
    tmux('set-option', '-g', 'default-command', '/bin/bash --noprofile --norc')

    wt = spawn('landed')
    snapshot('landed')
    teardown('landed')

    wt = spawn('unique')
    (wt/'unique.txt').write_text('must survive\n')
    git(wt, 'add', 'unique.txt'); git(wt, 'commit', '-m', 'unique local work')
    unique_head = git(wt, 'rev-parse', 'HEAD')
    teardown('unique', ok=False)
    assert git(wt, 'rev-parse', 'HEAD') == unique_head
    git(project, 'merge', '--ff-only', unique_head)
    log.write('Landed unique commit on disposable project main: '+unique_head+'\n')
    teardown('unique')

    wt = spawn('residual')
    (wt/'.session').mkdir(); (wt/'.session'/'transcript').write_text('private work to preserve\n')
    teardown('residual', ok=False)
    assert (wt/'.session'/'transcript').read_text() == 'private work to preserve\n'
    shutil.move(str(wt/'.session'), str(HOME/'data'/'residual'/'preserved-session'))
    log.write('Preserved residual session outside disposable copy in lab task data.\n')
    teardown('residual')

    wt = spawn('scout', scout=True)
    teardown('scout', ok=False)
    (HOME/'data'/'scout'/'report.md').write_text('# Scout result\nInvestigation complete. No unresolved decisions.\n')
    run('bash', 'bin/fm-captain-hold.sh', 'complete', 'scout', '--none')
    teardown('scout')
    assert (HOME/'data'/'scout'/'report.md').exists()
    log.write('Scout report remains after tab/copy/metadata removal.\n')

    wt = spawn('interrupted')
    tmux('kill-window', '-t', 'firstmate:fm-interrupted')
    git(project, 'worktree', 'remove', str(wt))
    log.write('Simulated interruption after actual endpoint and copy removal, before record retirement.\n')
    snapshot('interrupted')
    teardown('interrupted')
    log.write('ALL LIVE LIFECYCLE SCENARIOS PASSED\n')
finally:
    for process in watchers:
        if process.poll() is None:
            process.terminate(); process.wait(timeout=15)
    if socket_dir:
        tmux('kill-server', expect=None)
        run('bash', 'bin/fm-lab-home.sh', 'teardown', HOME)
    shutil.rmtree(LAB)
    log.write('Disposable lab and private tmux server removed.\n')
    log.close()
