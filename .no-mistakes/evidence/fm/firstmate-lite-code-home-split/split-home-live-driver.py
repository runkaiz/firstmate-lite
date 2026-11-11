import hashlib
import json
import os
from pathlib import Path
import shlex
import shutil
import subprocess
import time

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M74J2FXRW0T19K2EBYP5W0HC')
BASE = ROOT / '.phase-live' / 'world'
EVIDENCE = Path('/home/runkai/.no-mistakes/evidence/01M74J2FXRW0T19K2EBYP5W0HC')
BASE.mkdir()
log = (EVIDENCE / 'split-home-live.log').open('w', buffering=1)
env = dict(os.environ)
for key in list(env):
    if key.startswith(('FM_', 'TASKS_AXI_', 'GIT_')) or key in ('TMUX', 'TMUX_PANE', 'HERDR_SESSION'):
        env.pop(key)
env.update(GIT_CONFIG_GLOBAL='/dev/null', GIT_CONFIG_NOSYSTEM='1',
           GIT_AUTHOR_NAME='Split validation', GIT_AUTHOR_EMAIL='test@example.invalid',
           GIT_COMMITTER_NAME='Split validation', GIT_COMMITTER_EMAIL='test@example.invalid',
           XDG_DATA_HOME=str(BASE / 'install data'), TMPDIR=str(BASE))
results = []
processes = []
socket_dir = None
lab = BASE / 'watch home'
code = BASE / 'install data' / 'firstmate'
first = BASE / 'private home'
second = BASE / 'second home'
seed = BASE / 'origin'

def run(args, cwd=ROOT, extra=None, expected=0, timeout=45):
    args = [str(a) for a in args]
    log.write('$ ' + shlex.join(args) + '\n')
    e = env | (extra or {})
    p = subprocess.run(args, cwd=cwd, env=e, stdout=subprocess.PIPE,
                       stderr=subprocess.STDOUT, text=True, timeout=timeout)
    log.write(p.stdout + f'[exit {p.returncode}]\n')
    if expected is not None:
        assert p.returncode == expected, (args, p.returncode, p.stdout)
    return p

def verify(message, condition):
    assert condition, message
    log.write('OBSERVED: ' + message + '\n')

def scenario(name, fn):
    log.write('\nSCENARIO: ' + name + '\n')
    try:
        fn()
        results.append({'name': name, 'result': 'pass'})
        log.write('RESULT: pass\n')
    except Exception as exc:
        results.append({'name': name, 'result': 'fail', 'error': str(exc)})
        log.write('RESULT: fail ' + repr(exc) + '\n')

def snapshot(home):
    answer = {}
    for top in ('data', 'state', 'config', 'projects'):
        for p in sorted((home / top).rglob('*')):
            answer[str(p.relative_to(home))] = (
                p.lstat().st_mode,
                ('link', os.readlink(p)) if p.is_symlink() else
                ('file', hashlib.sha256(p.read_bytes()).hexdigest()) if p.is_file() else ('dir',))
    return answer

def launch(home, args, extra=None):
    return run([home / 'bin/fm-start.sh', *args], cwd=home, extra=extra)

def install():
    seed.mkdir()
    archive = BASE / 'target.tar'
    with archive.open('wb') as f:
        subprocess.run(['git', 'archive', 'HEAD'], cwd=ROOT, stdout=f, check=True)
    run(['tar', '-xf', archive, '-C', seed])
    run(['git', 'init', '-q', '-b', 'main', seed])
    run(['git', '-C', seed, 'add', '.'])
    run(['git', '-C', seed, 'commit', '-qm', 'target installation'])
    env.update(GIT_CONFIG_COUNT='1', GIT_CONFIG_KEY_0=f'url.file://{seed}.insteadOf',
               GIT_CONFIG_VALUE_0='https://github.com/runkaiz/firstmate-lite.git')
    run([ROOT / 'bin/fm-install.sh', first])
    run([ROOT / 'bin/fm-install.sh', second])
    for home in (first, second):
        verify(f'{home.name}: no independent checkout', not (home / '.git').exists())
        for top in ('data', 'state', 'config', 'projects'):
            p = home / top
            verify(f'{home.name}/{top}: private directory mode 700',
                   p.is_dir() and not p.is_symlink() and p.stat().st_mode & 0o777 == 0o700)
            (p / 'keep.txt').write_text(home.name + ' private ' + top + '\n')
        for link in ('bin', 'docs', '.agents/skills', '.claude/skills',
                     '.claude/settings.json', '.codex/hooks.json', '.pi/extensions', 'AGENTS.md'):
            verify(f'{home.name}/{link}: shared installed file',
                   (home / link).is_symlink() and (home / link).samefile(code / link))
        verify(f'{home.name}: Claude has direct shared instructions',
               (home / 'CLAUDE.md').samefile(code / 'AGENTS.md'))
    before = snapshot(first)
    run([ROOT / 'bin/fm-install.sh', first])
    verify('reinstall preserves every private file and mode', snapshot(first) == before)
    verify('shared checkout has no private directories',
           all(not (code / p).exists() for p in ('data', 'state', 'config', 'projects')))

def launcher_and_queue():
    probe = 'import os,sys,json;print(json.dumps(dict(cwd=os.getcwd(),home=os.environ["FM_HOME"],code=os.environ["FM_ROOT_OVERRIDE"],args=sys.argv[1:])))'
    p = launch(first, ['python3', '-c', probe, 'two words', '; literal $HOME'])
    obj = json.loads(p.stdout)
    verify('launcher scopes cwd and FM_HOME to selected private home, FM_ROOT_OVERRIDE to shared code',
           obj == {'cwd': str(first.resolve()), 'home': str(first.resolve()), 'code': str(code.resolve()), 'args': ['two words', '; literal $HOME']})
    p = run([code / 'bin/fm-start.sh', 'python3', '-c', probe, 'outside'], extra={'FM_HOME': str(second)})
    verify('explicit FM_HOME works from outside the home', Path(json.loads(p.stdout)['cwd']).samefile(second))
    launch(first, ['codex', '--version'])
    launch(first, ['bin/fm-queue.sh', 'add', 'same-id', 'First private queue', '--kind', 'ship', '--repo', 'sample'])
    launch(second, ['bin/fm-queue.sh', 'add', 'same-id', 'Second private queue', '--kind', 'ship', '--repo', 'sample'])
    p = launch(first, ['bin/fm-queue.sh', 'show', 'same-id'])
    q = launch(second, ['bin/fm-queue.sh', 'show', 'same-id'])
    verify('identical task ids retain independent private queue records',
           'First private queue' in p.stdout and 'Second private queue' not in p.stdout
           and 'Second private queue' in q.stdout and 'First private queue' not in q.stdout)

def combined():
    for top in ('data', 'state', 'config', 'projects'):
        (seed / top).mkdir(exist_ok=True)
    run([seed / 'bin/fm-queue.sh', 'add', 'legacy-id', 'Combined checkout queue', '--kind', 'ship', '--repo', 'sample'], cwd=seed)
    p = run([seed / 'bin/fm-queue.sh', 'show', 'legacy-id'], cwd=seed)
    verify('combined checkout still stores records under its own data directory without FM_HOME',
           'Combined checkout queue' in p.stdout and (seed / 'data/backlog.md').is_file())
    p = run([seed / 'bin/fm-start.sh', 'python3', '-c', 'import os; print(os.getcwd()); print(os.environ["FM_HOME"]); print(os.environ["FM_ROOT_OVERRIDE"])'], cwd=seed)
    verify('combined checkout launcher scopes code and home to the checkout',
           p.stdout.splitlines() == [str(seed.resolve())] * 3)

def refuse():
    collision = BASE / 'collision'
    collision.mkdir()
    (collision / 'bin').write_text('my existing commands\n')
    p = run([ROOT / 'bin/fm-install.sh', collision], expected=1)
    verify('collision is refused before initializing private directories',
           'would overwrite' in p.stdout and (collision / 'bin').read_text() == 'my existing commands\n'
           and not (collision / 'data').exists())
    linked = BASE / 'linked-private'
    linked.mkdir()
    (linked / 'data').symlink_to(first / 'data', target_is_directory=True)
    before = snapshot(first)
    p = run([ROOT / 'bin/fm-install.sh', linked], expected=1)
    verify('symlinked private directory is refused and destination unchanged',
           'must be a directory' in p.stdout and snapshot(first) == before)
    run([ROOT / 'bin/fm-install.sh', code / 'nested-home'], expected=1)
    run([ROOT / 'bin/fm-install.sh', BASE], expected=1)
    run([ROOT / 'bin/fm-install.sh', seed], expected=1)
    unmanaged = BASE / 'unmanaged-data'
    (unmanaged / 'firstmate').mkdir(parents=True)
    run([ROOT / 'bin/fm-install.sh', BASE / 'unused-home'],
        extra={'XDG_DATA_HOME': str(unmanaged)}, expected=1)
    bad = BASE / 'unlinked-home'
    bad.mkdir()
    run([code / 'bin/fm-start.sh', 'python3', '-c', 'raise SystemExit(99)'], cwd=bad, expected=1)
    verify('nested roots, existing checkout, unmanaged installation, and unrelated launch cwd all refused', True)

def update():
    version = seed / 'bin/split-live-version.sh'
    version.write_text('#!/bin/sh\nprintf "shared version two\\n"\n')
    version.chmod(0o755)
    run(['git', '-C', seed, 'add', version])
    run(['git', '-C', seed, 'commit', '-qm', 'publish new shared executable'])
    before = {str(h): snapshot(h) for h in (first, second)}
    p = launch(second, ['bin/fm-update.sh'])
    verify('update advances shared checkout and reports changed instruction surface',
           'firstmate: updated' in p.stdout and 'reread-firstmate: yes' in p.stdout)
    for home in (first, second):
        p = launch(home, ['bin/split-live-version.sh'])
        verify(home.name + ' immediately runs updated shared executable', p.stdout == 'shared version two\n')
        verify(home.name + ' private files and modes unchanged by update', snapshot(home) == before[str(home)])
    launch(first, ['bin/fm-update.sh'])
    (code / 'README.md').write_text((code / 'README.md').read_text() + '\nlocal uncommitted edit\n')
    old = run(['git', '-C', code, 'rev-parse', 'HEAD']).stdout
    p = launch(first, ['bin/fm-update.sh'])
    verify('dirty shared checkout is skipped without losing local edits',
           'dirty' in p.stdout and run(['git', '-C', code, 'rev-parse', 'HEAD']).stdout == old
           and (code / 'README.md').read_text().endswith('local uncommitted edit\n'))
    for home in (first, second):
        verify(home.name + ' private data unchanged after no-op and guarded update', snapshot(home) == before[str(home)])

def watcher():
    global socket_dir
    run([ROOT / 'bin/fm-lab-home.sh', 'create', lab])
    run([ROOT / 'bin/fm-install.sh', lab])
    socket_dir = run([ROOT / 'bin/fm-lab-home.sh', 'tmux-dir', lab]).stdout.strip()
    watchenv = {'FM_HOME': str(lab), 'FM_BACKEND': 'tmux', 'TMUX_TMPDIR': socket_dir,
                'FM_POLL': '1', 'FM_HEARTBEAT': '3600'}
    run(['tmux', '-L', 'fm-lab', 'new-session', '-d', '-s', 'watch-fixture', '-x', '120', '-y', '40', 'sleep', '180'], extra=watchenv)
    watchenv['TMUX'] = run(['tmux', '-L', 'fm-lab', 'display-message', '-p', '-t', 'watch-fixture', '#{socket_path},#{pid},0'], extra=watchenv).stdout.strip()
    for name, entry in [('physical', code / 'bin/fm-watch-arm.sh'), ('linked', lab / 'bin/fm-watch-arm.sh')]:
        outpath = EVIDENCE / f'watcher-{name}.log'
        f = outpath.open('w', buffering=1)
        p = subprocess.Popen([str(entry)], cwd=ROOT, env=env | watchenv, stdout=f, stderr=subprocess.STDOUT, start_new_session=True)
        processes.append((p, f))
        log.write('$ ' + str(entry) + f' [real background process {p.pid}; output {outpath.name}]\n')
        for _ in range(120):
            out = outpath.read_text()
            if 'watcher: started pid=' in out or 'watcher: attached pid=' in out or p.poll() is not None:
                break
            time.sleep(.1)
        log.write(out)
        verify(name + ' arm ' + ('starts a real watcher' if name == 'physical' else 'attaches to same watcher through home symlink'),
               ('watcher: started pid=' if name == 'physical' else 'watcher: attached pid=') in out)
        pid = (lab / 'state/.watch.lock/pid').read_text().strip()
        if name == 'physical':
            original = pid
        else:
            verify('linked arm preserves physical watcher pid, avoiding a duplicate', pid == original)
    sibling = BASE / 'sibling watch home'
    run([ROOT / 'bin/fm-lab-home.sh', 'create', sibling])
    run([ROOT / 'bin/fm-install.sh', sibling])
    sibling_env = watchenv | {'FM_HOME': str(sibling)}
    sibling_path = EVIDENCE / 'watcher-sibling.log'
    f = sibling_path.open('w', buffering=1)
    p = subprocess.Popen([str(sibling / 'bin/fm-watch-arm.sh')], cwd=ROOT,
                         env=env | sibling_env, stdout=f, stderr=subprocess.STDOUT,
                         start_new_session=True)
    processes.append((p, f))
    log.write('$ ' + str(sibling / 'bin/fm-watch-arm.sh') + f' [real background process {p.pid}]\n')
    for _ in range(120):
        out = sibling_path.read_text()
        if 'watcher: started pid=' in out or p.poll() is not None:
            break
        time.sleep(.1)
    log.write(out)
    verify('second home starts its own watcher using the same installation', 'watcher: started pid=' in out)
    sibling_pid = int((sibling / 'state/.watch.lock/pid').read_text())
    verify('separate homes use distinct watcher processes', sibling_pid != int(original))
    run([lab / 'bin/fm-watch-arm.sh', '--stop'], extra=watchenv)
    verify('linked home stop removes physical watcher lock', not (lab / 'state/.watch.lock').exists())
    os.kill(sibling_pid, 0)
    verify('stopping one home leaves the sibling watcher alive and locked',
           (sibling / 'state/.watch.lock/pid').read_text().strip() == str(sibling_pid))
    run([sibling / 'bin/fm-watch-arm.sh', '--stop'], extra=sibling_env)
    verify('shared installation still contains no private directories after runtime operations',
           all(not (code / p).exists() for p in ('data', 'state', 'config', 'projects')))
    run(['tmux', '-L', 'fm-lab', 'kill-server'], extra=watchenv)
    run([ROOT / 'bin/fm-lab-home.sh', 'teardown', lab])
    socket_dir = None

try:
    scenario('Install and reinstall two private homes using one shared checkout', install)
    if code.exists() and first.exists():
        scenario('Launch real commands and keep identical queue ids isolated by home', launcher_and_queue)
        scenario('Keep combined checkout commands working without a separate home', combined)
        scenario('Refuse collisions, symlinked private data, nested roots, and unrelated homes', refuse)
        scenario('Update shared code once without touching either private home', update)
        scenario('Attach and stop one real watcher through installation and home paths', watcher)
finally:
    for p, f in processes:
        if p.poll() is None:
            os.killpg(p.pid, 15)
        try:
            p.wait(timeout=10)
        except subprocess.TimeoutExpired:
            os.killpg(p.pid, 9)
            p.wait()
        f.close()
    if socket_dir:
        run(['tmux', '-L', 'fm-lab', 'kill-server'], extra={'TMUX_TMPDIR': socket_dir}, expected=None)
        run([ROOT / 'bin/fm-lab-home.sh', 'teardown', lab], expected=None)
    shutil.rmtree(BASE)
    log.write('\nCLEANUP: all disposable code, homes, Git fixture and private tmux server removed.\n')
    (EVIDENCE / 'split-home-results.json').write_text(json.dumps(results, indent=2) + '\n')
    log.close()
print(json.dumps(results, indent=2))
raise SystemExit(any(x['result'] != 'pass' for x in results))
