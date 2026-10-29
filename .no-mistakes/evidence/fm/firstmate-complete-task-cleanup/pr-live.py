import pathlib
helpers = pathlib.Path(__file__).with_name('cleanup-live.py').read_text().split('\ntry:\n', 1)[0]
exec(helpers.replace("'live-lifecycle.log'", "os.environ.get('VALIDATION_PR_LOG', 'live-pr.log')"))

PR = 'https://github.com/cli/safeexec/pull/9'
try:
    run('bash', 'bin/fm-lab-home.sh', 'create', HOME)
    socket_dir = run('bash', 'bin/fm-lab-home.sh', 'tmux-dir', HOME).stdout.strip()
    env['TMUX_TMPDIR'] = socket_dir
    env['TMUX'] = socket_dir + '/tmux-' + str(os.getuid()) + '/fm-lab,0,0'
    for key, value in {'worktree-allocator':'git', 'git-worktree-root':str(LAB/'copies'),
                       'backlog-backend':'manual', 'usage-ledger':'off', 'crew-harness':'codex'}.items():
        (HOME/'config'/key).write_text(value+'\n')
    (HOME/'data'/'projects.md').write_text('- safeexec [direct-PR]\n')
    project=LAB/'project'
    run('git','clone','--quiet','https://github.com/cli/safeexec.git',project)
    info=json.loads(run('gh','pr','view',PR,'--json','state,headRefOid,baseRefName,url,mergeCommit').stdout)
    assert info['state']=='MERGED'
    head=info['headRefOid']
    git(project,'fetch','origin','refs/pull/9/head')
    parent=git(project,'rev-parse',head+'^')
    tmux('-f','/dev/null','new-session','-d','-s','firstmate','-n','main','-x','120','-y','40','-c',ROOT,'/bin/bash --noprofile --norc')
    tmux('set-option','-g','default-command','/bin/bash --noprofile --norc')

    for id,unique in [('rebased-landed',False),('published-unique-parent',True)]:
        data=HOME/'data'/id; data.mkdir()
        (data/'brief.md').write_text('# Task\n## Captain\'s intent\nValidate preserved public PR history in a disposable clone.\n\n## Firstmate spec\nRead-only forge proof.\n')
        (HOME/'state'/'.last-watcher-beat').touch()
        run('bash','bin/fm-spawn.sh',id,project,'sleep 2','--mode','direct-PR','--yolo','off','--backend','tmux')
        time.sleep(3)
        wt=LAB/'copies'/id/'worktree'
        git(wt,'switch','-C','fm/'+id,parent)
        if unique:
            (wt/'unique-work.txt').write_text('must not be discarded merely because a child patch landed\n')
            git(wt,'add','unique-work.txt');git(wt,'commit','-m','unique parent')
            # A real Git remote-tracking ref models an already-published parent.
            # No remote mutation is performed.
            git(wt,'update-ref','refs/remotes/origin/unique-lab-parent','HEAD')
        git(wt,'cherry-pick','--no-commit',head)
        git(wt,'commit','-m','locally rebased PR patch')
        local=git(wt,'rev-parse','HEAD')
        git(wt,'update-ref','refs/remotes/origin/retained-lab-branch',local)
        with (HOME/'state'/(id+'.meta')).open('a') as f:
            f.write('pr='+PR+'\npr_head='+head+'\n')
        log.write('HISTORY '+json.dumps(dict(task=id,public_merged_head=head,local_head=local,
                   common_base=git(wt,'merge-base','HEAD',head),unique_parent=unique))+'\n')
        run('git','-C',wt,'log','--oneline','--all','--max-count=8')
        snapshot(id)
        teardown(id,ok=not unique)
        if unique:
            assert (wt/'unique-work.txt').read_text().startswith('must not')
            assert git(wt,'rev-parse','HEAD')==local
            log.write('Unique parent, committed bytes, task record and endpoint preserved.\n')
    log.write('ALL LIVE PUBLIC-PR SCENARIOS PASSED; no forge writes performed.\n')
finally:
    if socket_dir:
        tmux('kill-server',expect=None)
        run('bash','bin/fm-lab-home.sh','teardown',HOME)
    # Spawn seals hook records read-only; relax only disposable fixture dirs.
    for directory, subdirs, files in os.walk(LAB):
        if not os.path.islink(directory):
            os.chmod(directory, 0o700)
    shutil.rmtree(LAB)
    log.write('Disposable public clone, fixture data and private tmux server removed.\n')
    log.close()
