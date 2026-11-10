exec(open('.test-tmp/live-ahoy.py').read().split("h=home('mixed')")[0].replace("LAB=ROOT/'.test-tmp/live-ahoy'", "LAB=ROOT/'.test-tmp/live-progress'"))
h=ROOT/'.l'
run(['bin/fm-lab-home.sh','create',h]); (h/'tmux').mkdir()
(h/'projects/worker').mkdir()
run(['git','init','-q',h/'projects/worker'])
run(['git','-C',h/'projects/worker','-c','user.name=Live test','-c','user.email=live-test@example.invalid','commit','-q','--allow-empty','-m','Disposable worker'])
run(['git','-C',h/'projects/worker','checkout','-q','-b','fm/worker'])
run(['git','clone','-q','--bare',h/'projects/worker',h/'projects/remote.git'])
run(['git','-C',h/'projects/worker','remote','add','origin',str(h/'projects/remote.git')])
run(['git','-C',h/'projects/worker','fetch','-q','origin'])
(h/'data/backlog.md').write_text('## In flight\n- [ ] worker - Prepare importer follow-up (repo: example) (kind: ship)\n\n## Queued\n\n## Done\n')
job=h/'job.sh'
job.write_text('''#!/usr/bin/env bash
claude -p 'Run sleep 50 using Bash, then reply WORK_DONE.' --setting-sources project --settings '{"disableAllHooks":true,"autoMemoryEnabled":false}' --tools Bash --allowedTools Bash --strict-mcp-config --no-session-persistence --output-format stream-json --verbose > "$FM_HOME/cli.jsonl" 2> "$FM_HOME/cli.stderr"
bin/fm-busy-event.sh apply "$FM_HOME/state" worker idle --gen "$(cat "$FM_HOME/state/worker.busy-gen")" --source claude-hook --event stop
printf 'done: implementation finished, publication/CI verification skipped\n' > "$FM_HOME/state/worker.status"
sleep 120
''')
tenv=dict(env(h),TMUX_TMPDIR=str(h/'tmux'),FM_CREW_STATE_NO_FORGE='1',NM_HOME=str(h/'config/no-mistakes'))
for key in ['NO_MISTAKES_GATE','FM_GATE_REFUSE_BYPASS']:
    tenv.pop(key,None)
try:
    gen=run(['bin/fm-busy-event.sh','arm',h/'state','worker']).strip()
    (h/'state/worker.meta').write_text(f'window=primary:0.0\nworktree={h}/projects/worker\nbackend=tmux\nharness=claude\nkind=ship\nmode=direct-PR\nproject=example\nspawn_gen=s{int(time.time())}.{os.getpid()}.1\npr=https://github.com/ahoy-lab/example/pull/4\n')
    (h/'state/worker.status').write_text('working: preparing the follow-up\n')
    run(['bin/fm-busy-event.sh','apply',h/'state','worker','busy','--gen',gen,'--source','claude-hook','--event','user-prompt-submit'])
    run(['tmux','-L','fm-lab','new-session','-d','-s','primary','-x','120','-y','40','-c',ROOT,'-e',f'FM_HOME={h}','bash',str(job)],tenv)
    sock=run(['tmux','-L','fm-lab','display-message','-p','#{socket_path},#{pid},0'],tenv).strip()
    tenv['TMUX']=sock
    for _ in range(100):
        if (h/'cli.jsonl').exists() and 'sleep 50' in (h/'cli.jsonl').read_text(): break
        time.sleep(.2)
    a=json.loads(run(['bin/fm-bearings-snapshot.sh','--json','--record-look'],tenv))
    (EV/'moving-real-worker.json').write_text(json.dumps(a,indent=2))
    assert any(x['id']=='worker' and x['state']=='working' and x['stage']=='implementing' and x['elapsed_seconds'] is not None for x in a['in_flight']),a['in_flight']
    saved_base=BASE.copy()
    BASE.update({'TMUX':sock,'TMUX_TMPDIR':str(h/'tmux'),'FM_CREW_STATE_NO_FORGE':'1','NM_HOME':str(h/'config/no-mistakes')})
    chat(h,'native-ahoy-real-moving')
    for _ in range(220):
        if (h/'state/worker.status').read_text().startswith('done:'): break
        time.sleep(.2)
    a=json.loads(run(['bin/fm-bearings-snapshot.sh','--json','--record-look'],tenv))
    (EV/'completion-real-worker.json').write_text(json.dumps(a,indent=2))
    assert any(x['id']=='worker' and x['state']=='done' and x['stage']=='done' for x in a['in_flight']),a['in_flight']
    # Native Ahoy sees the same private tmux server as the real worker.
    BASE['TMUX']=sock
    BASE['TMUX_TMPDIR']=str(h/'tmux')
    source=chat.__code__
    # The standard chat evaluator uses project skill discovery.
    chat_source=open('.test-tmp/live-ahoy-r2.py').read().split("h=home('mixed')")[0]
    exec(chat_source[chat_source.index('def chat('):],globals())
    chat(h,'native-ahoy-real-completion')
    shutil.copy2(h/'cli.jsonl',EV/'real-worker-cli.jsonl')
    (EV/'real-worker-pane.txt').write_text(run(['tmux','-L','fm-lab','capture-pane','-p','-t','primary','-S','-200'],tenv))
    print('LIVE_PROGRESS_COMPLETE',flush=True)
finally:
    subprocess.run(['tmux','-L','fm-lab','kill-server'],env=tenv,capture_output=True)
    shutil.rmtree(h)
