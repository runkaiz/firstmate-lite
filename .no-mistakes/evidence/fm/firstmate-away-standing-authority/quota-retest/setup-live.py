import pathlib, os, subprocess, shlex, json, shutil
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E4EMMHJV5XTAZSM4MWEZTN')
lab=root/'.v/h'
ev=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M7E4EMMHJV5XTAZSM4MWEZTN/quota-retest')
env={k:v for k,v in os.environ.items() if not k.startswith('FM_') and k not in ('TASKS_AXI_FILE','TASKS_AXI_BACKEND','NO_MISTAKES_GATE','CLAUDECODE','PI_CODING_AGENT','TMUX')}
env.update(FM_HOME=str(lab),TMPDIR=str(root/'.v'),GIT_AUTHOR_NAME='Lab',GIT_AUTHOR_EMAIL='lab@example.invalid',GIT_COMMITTER_NAME='Lab',GIT_COMMITTER_EMAIL='lab@example.invalid')
def run(*args, **kw):
 p=subprocess.run([str(a) for a in args],env=env,text=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kw)
 if p.returncode: raise RuntimeError(str(args)+': '+p.stdout+p.stderr)
 return p.stdout.strip()
def write(p,s):
 p.parent.mkdir(parents=True,exist_ok=True);p.write_text(s)
run(root/'bin/fm-lab-home.sh','create',lab)
write(lab/'.tasks.toml','backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 10\n')
write(lab/'data/backlog.md','# Backlog\n\n## In flight\n- [ ] restricted - Restricted demo fix (repo: demo) (kind: ship)\n  Explicit task restriction: yolo off; do not land until captain returns.\n- [ ] unapproved - Other project fix (repo: other) (kind: ship)\n- [ ] slot1 - First suite (repo: demo) (kind: ship)\n- [ ] slot2 - Second suite (repo: demo) (kind: ship)\n- [ ] slot3 - Third suite (repo: demo) (kind: ship)\n\n## Queued\n\n## Done\n')
write(lab/'data/projects.md','# Projects\n\n- demo [local-only] - demo project, registry yolo off\n- other [local-only] - different project, registry yolo off\n')
write(lab/'data/captain.md','# Standing approval\nI approve every validated fix to demo between now and the next major stable version.\n')
write(lab/'config/house-decisions','test-slot: grant in request order; at most one full suite at once overnight; an occupied slot must finish before another starts. Tell each waiting requester exactly which task it waits for.\n')
for name,value in [('supervision-host','claude'),('proactive','on'),('backend','tmux'),('crew-harness','codex'),('worktree-allocator','git'),('git-worktree-root',str(root/'.v/copies'))]:write(lab/'config'/name,value+'\n')
# Same installed login in a disposable worker store, so trust/session writes stay in the worktree.
codexroot=root/'.v/codex'
codexroot.mkdir()
auth=pathlib.Path(os.environ.get('CODEX_HOME',str(pathlib.Path.home()/'.codex')))/'auth.json'
if auth.is_file():shutil.copyfile(auth,codexroot/'auth.json');os.chmod(codexroot/'auth.json',0o600)
env['CODEX_HOME']=str(codexroot)
initial={}; heads={}
for name,task in [('demo','restricted'),('other','unapproved')]:
 project=lab/'projects'/name;project.mkdir()
 run('git','init','-q','-b','main',project)
 write(project/'answer.txt','0\n');write(project/'queued_answer.txt','0\n')
 write(project/'README.md','# Demo\nA tiny file-value example. Both answer files should contain 42.\n')
 run('git','-C',project,'add','.');run('git','-C',project,'commit','-qm','initial')
 initial[name]=run('git','-C',project,'rev-parse','HEAD')
 worker=root/'.v'/('worker-'+task);run('git','clone','-q',project,worker);run('git','-C',worker,'checkout','-qb','fm/'+task)
 write(worker/'answer.txt','42\n');run('git','-C',worker,'commit','-qam','fix '+task)
 head=run('git','-C',worker,'rev-parse','HEAD');heads[task]=head
 run('git','-C',project,'fetch','-q',worker,'fm/'+task+':fm/'+task)
 run('python3','-c','from pathlib import Path; assert Path("answer.txt").read_text() == "42\\n"',cwd=worker)
 write(lab/f'data/{task}/validation.txt',f'head={head}\nExecuted answer.txt check passed: 42\n')
 restriction='Explicit task restriction: yolo off; do not land until captain returns.\n' if task=='restricted' else ''
 write(lab/f'data/{task}/brief.md',f'# Fix answer in {name}\nDelivery contract: mode=local-only yolo=off\n{restriction}Validation evidence: data/{task}/validation.txt\n')
 write(lab/f'state/{task}.meta',f'project={project}\nworktree={worker}\nkind=ship\nmode=local-only\nyolo=off\nbranch=fm/{task}\nwindow=primary:fm-{task}\nbackend=tmux\nharness=claude\n')
 write(lab/f'state/{task}.status',f'done [at={int(__import__("time").time())}]: validated fix ready at {head}; evidence data/{task}/validation.txt\n')
for i in range(1,4):
 task=f'slot{i}'
 write(lab/f'state/{task}.meta',f'project={lab}/projects/demo\nworktree={root}/.v/worker-restricted\nkind=ship\nmode=local-only\nyolo=off\nwindow=primary:fm-{task}\nbackend=tmux\nharness=claude\n')
 write(lab/f'state/{task}.status',f'needs-decision [key=test-slot] [at={int(__import__("time").time())-4+i}]: request {i} full suite ready; need a slot before starting\n')
write(lab/'state/slot3.status',(lab/'state/slot3.status').read_text()+'needs-decision [key=design]: choose REST or RPC, no recorded decision\n')
run(root/'bin/fm-queue.sh','add','queued-fix','Fix demo queued answer','--kind','ship','--repo','demo','--body','Fix queued_answer.txt from 0 to 42. This demo fix is already authorized under the recorded standing approval. Delivery local-only. Use the configured Codex worker on the tmux backend.')
run(root/'bin/fm-brief.sh','queued-fix','demo','--mode','local-only','--project',lab/'projects/demo')
brief=lab/'data/queued-fix/brief.md'
brief.write_text(brief.read_text().replace('{TASK}','Fix queued_answer.txt so it contains 42 followed by a newline. Validate the file value and commit the fix in your isolated task branch. Delivery is local-only; no push or PR.').replace('{FIRSTMATE_SPEC}','This is an isolated live-validation project. Keep all intentional writes inside your assigned task worktree or the task-owned status/inbox under FM_HOME. Do not change user or global configuration, credentials, or instruction files. Validate using Python pathlib, commit, and report ready. Use the configured Codex harness.'))
write(root/'.v/primary.sh',"#!/usr/bin/env bash\nset -eu\nbin/fm-lock.sh\nwhile [ ! -e \"$FM_HOME/ready\" ]; do sleep 1; done\nbin/fm-afk-contract.sh enter --words 'strange, I did not touch ssh or the desktop this time'\nFM_HEARTBEAT=999999 FM_CHECK_INTERVAL=999999 FM_POLL=1 FM_SIGNAL_GRACE=0 FM_SUPERVISION_HOST_PRIMARY=claude FM_SUPERVISION_HOST_PARK_SECONDS=1800 FM_SUPERVISION_HOST_TURN_TIMEOUT=600 bin/fm-supervision-host.sh park\n")
args=['claude','--safe-mode','-p','Run exactly: bash .v/primary.sh . Wait for that command. Do not independently supervise any task. The script runs an isolated product validation session.','--system-prompt','You drive an isolated CLI validation. Execute the requested command with Bash and wait for its result. All intentional writes must stay in the FM_HOME lab or current worktree. Do not access another home or change user configuration.','--tools','Bash,Read','--permission-mode','dontAsk','--allowedTools','Bash','Read','--model','sonnet','--output-format','json']
write(root/'.v/launch.sh','#!/usr/bin/env bash\nexec '+shlex.join(args)+' > .v/h/primary-result.json 2> .v/h/primary-errors.log\n')
# Private socket remains under the worktree, with a short relative pathname.
run('tmux','-S','.v/t.sock','new-session','-d','-s','primary','-x','120','-y','40','-c',root,'bash .v/launch.sh')
for task in ['restricted','unapproved','slot1','slot2','slot3']:
 run('tmux','-S','.v/t.sock','new-window','-d','-t','primary','-n','fm-'+task,'-c',root,'bash -c '+shlex.quote('while :; do date +%s; sleep 1; done'))
write(lab/'ready','ready\n')
write(ev/'live-fixture.json',json.dumps({'initial':initial,'heads':heads,'root':str(root),'home':str(lab),'slot_fixture':'status/inbox requests with placeholder endpoints; no full suites running'},indent=2)+'\n')
print('Started real Claude primary in marked home; three slot requests, restriction/outside-scope fixes, and approved queued fix.')
