import os, subprocess, time, json, shutil
from pathlib import Path
root=Path.cwd()
evidence=Path('/home/runkai/.no-mistakes/evidence/01M73RFQ2ZN4FRRV48HJA6BDRH')
lab=evidence/'pi-lab'
assert not lab.exists()
subprocess.run(['bash','bin/fm-lab-home.sh','create',str(lab)],check=True,capture_output=True)
(lab/'tmux').mkdir(); (lab/'agent').mkdir()
# Disable every automatic discovery route and startup network activity; explicit
# product extension and skill remain real. No provider or credential is supplied.
env=os.environ.copy()
for k in list(env):
    if k in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS'] or (k.startswith('FM_') and k.endswith('_OVERRIDE')): env.pop(k)
env.update(FM_HOME=str(lab),TMUX_TMPDIR=str(lab/'tmux'),PI_CODING_AGENT_DIR=str(lab/'agent'),PI_TELEMETRY='0',TERM='xterm-256color')
def tmux(*args,check=True):
    return subprocess.run(['tmux','-L','fm-lab',*args],env=env,text=True,capture_output=True,check=check).stdout
def capture(name):
    screen=tmux('capture-pane','-p','-S','-200','-t','primary')
    (evidence/(name+'.txt')).write_text(screen)
    print('CAPTURE',name); print(screen)
    return screen
def send(text):
    print('INPUT',text)
    tmux('send-keys','-t','primary','-l',text); tmux('send-keys','-t','primary','Enter'); time.sleep(2)
try:
    cmd=['pi','--offline','--no-extensions','--extension',str(root/'.pi/extensions/fm-stow.ts'),'--no-mcp','--no-context-files','--no-prompt-templates','--no-themes','--session-dir',str(lab/'sessions'),'--skill',str(root/'.agents/skills/fastmode/SKILL.md'),'--approve','--tui-mode','regular']
    tmux('new-session','-d','-s','primary','-x','110','-y','36','-c',str(root),'-e','FM_HOME='+str(lab),*cmd)
    time.sleep(4)
    start=capture('pi-startup')
    # A real ancestor owns this disposable home, matching the production lock contract.
    pane_pid=tmux('display-message','-p','-t','primary','#{pane_pid}').strip()
    assert pane_pid.isdigit()
    (lab/'state/.lock').write_text(pane_pid+'\n')
    send('/fastmode maybe')
    invalid=capture('pi-invalid-action')
    assert 'Usage: /fastmode [on|off|status]' in invalid
    assert not (lab/'config/worker-fast-mode').exists()
    (lab/'state/.lock').write_text('1\n')
    send('/fastmode on')
    foreign=capture('pi-foreign-owner')
    assert '/fastmode requires the owning Firstmate session.' in foreign
    assert not (lab/'config/worker-fast-mode').exists()
    (lab/'state/.lock').write_text(pane_pid+'\n')
    send('/fastmode on')
    positive=capture('pi-valid-command')
    print('Presence flag after command:',(lab/'config/worker-fast-mode').exists())
    print('Actual Pi process and command ran; no provider, login, or response was simulated.')
finally:
    tmux('kill-server',check=False)
    shutil.rmtree(lab)
    print('Private fm-lab tmux server stopped and lab home removed.')
