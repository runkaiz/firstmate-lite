import os, sys, json, pathlib, shutil, subprocess, hashlib, time, threading, http.server, shlex
R=pathlib.Path(__file__).parent
E=pathlib.Path(sys.argv[1]); W=R/'.lv'; H=R/'l'; H2=W/'second home'; C=W/'share'/'firstmate'; S=W/'origin'
log=[]; results=[]; children=[]
env=os.environ.copy()
for k in list(env):
    if k.startswith(('FM_','TASKS_AXI_')) or k in ('NO_MISTAKES_GATE','TMUX','CLAUDECODE','CODEX_THREAD_ID'):
        env.pop(k,None)
env.update(HOME=str(W/'user'),XDG_DATA_HOME=str(W/'share'),XDG_CONFIG_HOME=str(W/'xdg'),XDG_CACHE_HOME=str(W/'cache'),TMPDIR=str(W/'tmp'),CODEX_HOME=str(W/'codex'),CLAUDE_CONFIG_DIR=str(W/'claude'),PI_CODING_AGENT_DIR=str(W/'pi'),GIT_CONFIG_NOSYSTEM='1',GIT_CONFIG_GLOBAL='/dev/null',GIT_AUTHOR_NAME='Live validation',GIT_AUTHOR_EMAIL='live@example.invalid',GIT_COMMITTER_NAME='Live validation',GIT_COMMITTER_EMAIL='live@example.invalid',PI_TELEMETRY='0')
def run(args,cwd=R,extra=None,check=True,record=True):
    en={**env,**(extra or {})}
    p=subprocess.run(['rtk',*map(str,args)],cwd=str(cwd),env=en,text=True,stdout=subprocess.PIPE,stderr=subprocess.STDOUT,timeout=60)
    if record: log.append('$ '+shlex.join(map(str,args))+'\n'+p.stdout+'[exit '+str(p.returncode)+']')
    if check and p.returncode: raise RuntimeError(log[-1] if record else p.stdout)
    return p

def snapshot(home):
    out={}
    for d in ['data','state','config','projects']:
        for p in [home/d,*sorted((home/d).rglob('*'))]:
            st=p.lstat(); out[str(p.relative_to(home))]={'mode':st.st_mode,'mtime_ns':st.st_mtime_ns,'sha256':hashlib.sha256(p.read_bytes()).hexdigest() if p.is_file() and not p.is_symlink() else None,'link':os.readlink(p) if p.is_symlink() else None}
    return out

def passed(name,detail):
    results.append({'name':name,'result':'pass','detail':detail}); log.append('OBSERVED '+name+': '+detail)
try:
    W.mkdir(); (W/'tmp').mkdir()
    for p in ['user','codex','claude','pi']: (W/p).mkdir()
    S.mkdir()
    # Copy the target's tracked bytes, never another checkout or the bare gate repository.
    archive=subprocess.run(['rtk','git','archive','HEAD'],cwd=R,stdout=subprocess.PIPE,check=True).stdout
    subprocess.run(['rtk','tar','-x','-C',str(S)],input=archive,check=True)
    run(['git','init','-q','-b','main',S]); run(['git','-C',S,'add','.']); run(['git','-C',S,'commit','-qm','target fixture'])
    env.update(GIT_CONFIG_COUNT='1',GIT_CONFIG_KEY_0='url.file://'+str(S)+'.insteadOf',GIT_CONFIG_VALUE_0='https://github.com/runkaiz/firstmate-lite.git')
    run([R/'bin/fm-lab-home.sh','create',H])
    for home in [H,H2]: run([R/'bin/fm-install.sh',home])
    for home,marker in [(H,'first-private'),(H2,'second-private')]:
        for d in ['data','state','config','projects']: (home/d/'keep').write_text(marker+' '+d+'\n')
    before=[snapshot(h) for h in [H,H2]]
    run([R/'bin/fm-install.sh',H]); assert before==[snapshot(h) for h in [H,H2]]
    assert not (H/'.git').exists()
    assert all(not (C/d).exists() for d in ['data','state','config','projects'])
    assert os.path.samefile(H/'bin',H2/'bin') and os.path.samefile(H/'AGENTS.md',C/'AGENTS.md')
    log.append('HOME LINKS '+json.dumps({str(p.relative_to(H)):os.readlink(p) for p in [H/'AGENTS.md',H/'CLAUDE.md',H/'bin',H/'.agents/skills',H/'.claude/settings.json',H/'.codex/hooks.json',H/'.pi/extensions']},indent=2))
    passed('Install two private homes and reinstall safely','Both homes share the same code and native instruction/skill links; no private directories in code; reinstall preserves all private bytes and timestamps.')
    collision=W/'collision'; collision.mkdir(); (collision/'AGENTS.md').write_text('existing owner instructions\n')
    p=run([R/'bin/fm-install.sh',collision],check=False); assert p.returncode and 'would overwrite' in p.stdout and (collision/'AGENTS.md').read_text()=='existing owner instructions\n'
    for bad in [C,C/'nested',W/'share']:
        p=run([R/'bin/fm-install.sh',bad],check=False); assert p.returncode
    sy=W/'linked-home'; sy.mkdir(); (sy/'data').symlink_to(H/'data',target_is_directory=True)
    p=run([R/'bin/fm-install.sh',sy],check=False); assert p.returncode and not (sy/'state').exists()
    run(['git','init','-q',W/'checkout'])
    p=run([R/'bin/fm-install.sh',W/'checkout'],check=False); assert p.returncode
    passed('Refuse collisions and overlapping code/home paths','Existing instructions, checkout, symlinked private directory, equal roots and both nesting directions were refused without overwriting private files.')
    cmd=['python3','-c','import os,sys,json; print(json.dumps(dict(cwd=os.getcwd(),home=os.environ["FM_HOME"],code=os.environ["FM_ROOT_OVERRIDE"],args=sys.argv[1:])))','space argument','--literal=$()']
    p=run([H/'bin/fm-start.sh',*cmd],cwd=H); got=json.loads(p.stdout)
    assert got==dict(cwd=str(H),home=str(H),code=str(C),args=['space argument','--literal=$()'])
    p=run([C/'bin/fm-start.sh',*cmd],extra={'FM_HOME':str(H2)}); got=json.loads(p.stdout); assert got['cwd']==str(H2) and got['home']==str(H2)
    p=run([C/'bin/fm-start.sh','python3','-c','raise SystemExit(23)'],extra={'FM_HOME':str(H)},check=False); assert p.returncode==23
    p=run([C/'bin/fm-start.sh','python3','-c','print("SHOULD NOT RUN")'],cwd=W,check=False); assert p.returncode and 'SHOULD NOT RUN' not in p.stdout
    passed('Launch from a home or select a home explicitly','Actual child process sees selected cwd and FM_HOME, shared FM_ROOT_OVERRIDE, exact argv and exit status; invalid home refuses before executing child.')
    # An ordinary public command writes each selected home, not the shared installation.
    for home in [H,H2]:
        run([home/'bin/fm-start.sh','bin/fm-queue.sh','add','isolated-row','Only '+home.name,'--kind','ship','--repo','sample'],cwd=home)
        run([home/'bin/fm-start.sh','bin/fm-queue.sh','show','isolated-row'],cwd=home)
    assert (H/'data/backlog.md').read_bytes() != (H2/'data/backlog.md').read_bytes()
    assert not (C/'data').exists()
    passed('Use the same queue command in two homes','Identically named items are stored independently in each private backlog; shared code has no data directory.')
    before=[snapshot(h) for h in [H,H2]]
    # Modify an executable and a skill in the disposable upstream, leaving memory files untouched.
    action=S/'bin/live-update-proof.sh'; action.write_text('#!/bin/sh\nprintf "shared version two\\n"\n'); action.chmod(0o755)
    skill=S/'.agents/skills/ahoy/SKILL.md'; skill.write_text(skill.read_text()+'\n<!-- disposable shared update proof -->\n')
    run(['git','-C',S,'add',str(action),str(skill)]); run(['git','-C',S,'commit','-qm','shared version two'])
    p=run([H2/'bin/fm-start.sh','bin/fm-update.sh'],cwd=H2); assert 'firstmate: updated' in p.stdout and 'reread-firstmate: yes' in p.stdout
    assert before==[snapshot(h) for h in [H,H2]]
    for home in [H,H2]: assert run([home/'bin/live-update-proof.sh']).stdout.strip()=='shared version two'
    (E/'private-snapshot.json').write_text(json.dumps({'before':before,'after':[snapshot(h) for h in [H,H2]]},indent=2))
    passed('Update shared code without changing either private home','A real Git fast-forward makes the new executable visible in both homes; all private content, file modes and timestamps remain identical.')
    (C/'README.md').write_text((C/'README.md').read_text()+'\nlocal uncommitted edit\n')
    p=run([H/'bin/fm-start.sh','bin/fm-update.sh'],cwd=H); assert 'dirty working tree' in p.stdout
    run(['git','-C',C,'restore','README.md']); run(['git','-C',C,'switch','-q','-c','local-work'])
    p=run([H/'bin/fm-start.sh','bin/fm-update.sh'],cwd=H); assert 'on local-work, expected main' in p.stdout
    run(['git','-C',C,'switch','-q','main'])
    passed('Preserve local code edits and branches during update','Shared update refuses dirty code and a non-default branch rather than overwriting or switching them.')
    (E/'live-checks.json').write_text(json.dumps(results,indent=2))
    (E/'live-cli-transcript.log').write_text('\n\n'.join(log)+'\n')
    # Leave fixtures only while the native checks are driven in this same evidence turn.
    (W/'ready').write_text('ready')
except Exception as e:
    log.append('FAIL '+repr(e)); (E/'live-cli-transcript.log').write_text('\n\n'.join(log)+'\n'); raise
