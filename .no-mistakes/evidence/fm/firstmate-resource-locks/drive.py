import json
import os
from pathlib import Path
import shlex
import signal
import subprocess
import time

ROOT = Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ')
LAB = ROOT / '.test-live/manual'
EVIDENCE = Path('/home/runkai/.no-mistakes/evidence/01M7E5G3VE4WRF2AH7TSMB9MDJ')
LOCK = str(ROOT / 'bin/fm-resource-lock.sh')
LAB.mkdir(parents=True)
HOME = LAB / 'home'
(HOME / 'config').mkdir(parents=True)
(LAB / 'run').mkdir()
DECL = HOME / 'config/resource-locks'
DECL.write_text('suite 2 22:00-09:00=1 full test-suite runs\ngpu 1 any GPU use\n')
env = {k: v for k, v in os.environ.items() if not k.startswith('FM_')}
env.update(FM_HOME=str(HOME), XDG_RUNTIME_DIR=str(LAB / 'run'), FM_RESOURCE_LOCK_POLL_SECS='0.05', FM_RESOURCE_LOCK_NOW='23:00')
log = (EVIDENCE / 'resource-lock-live.log').open('w', buffering=1)
jobs = []

def say(s):
    log.write(s + '\n')
    print(s, flush=True)

def run(args, e=None, expected=0):
    say('$ ' + shlex.join(map(str, args)))
    p = subprocess.run(list(map(str, args)), env=e or env, text=True, capture_output=True, timeout=15)
    say(p.stdout + p.stderr + f'[exit {p.returncode}]')
    assert p.returncode == expected, (args, p.returncode)
    return p.stdout

def start(name, args, e=None):
    say('$ ' + name + ': ' + shlex.join(map(str, args)))
    f = (LAB / (name + '.output')).open('w')
    p = subprocess.Popen(list(map(str, args)), env=e or env, stdout=f, stderr=f, start_new_session=True)
    jobs.append((name, p, f))
    return p

def until(fn):
    end = time.monotonic() + 12
    while not fn():
        assert time.monotonic() < end, 'timed out'
        time.sleep(.05)

def content(name):
    return (LAB / (name + '.output')).read_text()

def dump(name):
    say(name + ':\n' + content(name))

def held(name, resource):
    until(lambda: f'holding {resource}' in content(name))

def waiting(name, resource):
    until(lambda: f'waiting for {resource}' in content(name))

def release(path):
    say('$ release ' + str(path))
    path.touch()

try:
    say('SCENARIO: generated instructions provide declaration order and an executable wrapper')
    brief = run([LOCK, 'brief'])
    assert brief.index('- `suite`') < brief.index('- `gpu`')
    assert 'outermost to innermost' in brief and 'child processes retaining the lock' in brief
    (EVIDENCE / 'resource-lock-brief.md').write_text(brief)
    for kind, flags in [('ship', ['--mode', 'local-only']), ('scout', ['--scout'])]:
        run([ROOT / 'bin/fm-brief.sh', 'manual-' + kind, 'fixture', *flags])
        generated = (HOME / 'data' / ('manual-' + kind) / 'brief.md').read_text()
        assert brief.strip() in generated
        (EVIDENCE / (kind + '-brief.md')).write_text(generated)

    say('SCENARIO: two daytime jobs run while a third waits, then all finish')
    day = dict(env, FM_RESOURCE_LOCK_NOW='12:00')
    done = LAB / 'day.release'
    hold = ['sh', '-c', 'echo "$1 started"; while [ ! -e "$2" ]; do sleep .05; done; echo "$1 finished"', 'job']
    a = start('day-a', [LOCK, 'run', 'suite', '--', *hold, 'A', done], day)
    held('day-a', 'suite')
    b = start('day-b', [LOCK, 'run', 'suite', '--', *hold, 'B', done], day)
    held('day-b', 'suite')
    c = start('day-c', [LOCK, 'run', 'suite', '--', 'echo', 'C started'], day)
    waiting('day-c', 'suite')
    assert 'C started' not in content('day-c')
    dump('day-a'); dump('day-b'); dump('day-c')
    release(done)
    for p in [a, b, c]:
        assert p.wait(timeout=12) == 0
    dump('day-c')

    say('SCENARIO: overnight admission counts an existing daytime holder in slot 2')
    night_release = LAB / 'night.release'
    plain = start('plain-suite', ['flock', LAB / 'run/suite-slot-2.lock', *hold, 'legacy slot 2 holder', night_release])
    until(lambda: 'started' in content('plain-suite'))
    night = start('night', [LOCK, 'run', 'suite', '--', 'echo', 'night command ran'])
    waiting('night', 'suite')
    assert 'night command ran' not in content('night')
    dump('plain-suite'); dump('night')
    release(night_release)
    assert plain.wait(timeout=12) == night.wait(timeout=12) == 0
    dump('night')

    say('SCENARIO: competing nested jobs retain outer suite slot while GPU is unavailable')
    gpu_release = LAB / 'gpu.release'
    plain = start('plain-gpu', ['flock', LAB / 'run/gpu.lock', *hold, 'legacy GPU holder', gpu_release])
    until(lambda: 'started' in content('plain-gpu'))
    first = start('nested-first', [LOCK, 'run', 'suite', '--', LOCK, 'run', 'gpu', '--', 'sh', '-c', 'echo first-ran; sleep .3'])
    waiting('nested-first', 'gpu')
    second = start('nested-second', [LOCK, 'run', 'suite', '--', LOCK, 'run', 'gpu', '--', 'echo', 'second-ran'])
    waiting('nested-second', 'suite')
    assert 'first-ran' not in content('nested-first')
    assert 'second-ran' not in content('nested-second')
    dump('nested-first'); dump('nested-second')
    release(gpu_release)
    for p in [plain, first, second]:
        assert p.wait(timeout=12) == 0
    dump('nested-first'); dump('nested-second')

    say('SCENARIO: background descendants retain the slot after their parent exits')
    child_release = LAB / 'child.release'
    child = start('child-holder', [LOCK, 'run', 'gpu', '--', 'sh', '-c', '(while [ ! -e "$1" ]; do sleep .05; done; echo child-exited) & echo parent-exited', 'parent', child_release])
    assert child.wait(timeout=12) == 0
    waiter = start('child-waiter', [LOCK, 'run', 'gpu', '--', 'echo', 'after-child-ran'])
    waiting('child-waiter', 'gpu')
    assert 'after-child-ran' not in content('child-waiter')
    dump('child-holder'); dump('child-waiter')
    release(child_release)
    assert waiter.wait(timeout=12) == 0
    dump('child-holder'); dump('child-waiter')

    say('SCENARIO: local homes use the root declaration and share the GPU lock')
    child_home = LAB / 'secondmate'
    (child_home / 'config').mkdir(parents=True)
    (child_home / '.fm-secondmate-parent').write_text(f'schema=fm-secondmate-parent.v1\nroute=local\nparent_home={HOME}\n')
    (child_home / 'config/resource-locks').write_text('gpu 9 conflicting local declaration must not apply\n')
    mate_env = dict(env, FM_HOME=str(child_home))
    mate_brief = run([LOCK, 'brief'], mate_env)
    assert '`gpu` (1 at once)' in mate_brief
    cross_release = LAB / 'cross.release'
    owner = start('root-gpu', [LOCK, 'run', 'gpu', '--', *hold, 'root GPU holder', cross_release])
    held('root-gpu', 'gpu')
    mate = start('mate-gpu', [LOCK, 'run', 'gpu', '--', 'echo', 'local home ran'], mate_env)
    waiting('mate-gpu', 'gpu')
    assert 'local home ran' not in content('mate-gpu')
    dump('root-gpu'); dump('mate-gpu')
    release(cross_release)
    assert owner.wait(timeout=12) == mate.wait(timeout=12) == 0
    dump('mate-gpu')

    say('SCENARIO: invalid and zero-window declarations refuse before command or partial scaffold')
    DECL.write_text('suite 2 22:00-09:00=0 full test-suite runs\n')
    marker = LAB / 'must-not-run'
    run([LOCK, 'brief'], expected=1)
    run([LOCK, 'run', 'suite', '--', 'touch', marker], expected=1)
    run([ROOT / 'bin/fm-brief.sh', 'invalid', 'fixture', '--scout'], expected=1)
    assert not marker.exists() and not (HOME / 'data/invalid').exists()
    run([LOCK, 'list'], expected=2)
    DECL.write_text('gpu 1 any GPU use\n')
    say('SCENARIO: command arguments and exit status survive the wrapper')
    value = run([LOCK, 'run', 'gpu', '--', 'sh', '-c', 'printf "arg=<%s>\\n" "$@"; exit 7', 'argv', 'two words', '', 'literal$()'], expected=7)
    assert value == 'arg=<two words>\narg=<>\narg=<literal$()>\n'
    say('All direct CLI scenarios passed. No operator home or runtime files were used.')
finally:
    for name, p, f in jobs:
        try:
            os.killpg(p.pid, signal.SIGTERM)
        except ProcessLookupError:
            pass
        p.wait(timeout=5)
        f.close()
    log.close()
