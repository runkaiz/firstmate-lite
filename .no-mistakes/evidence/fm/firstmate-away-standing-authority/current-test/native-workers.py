import os, pathlib, subprocess, shlex, json
root=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E4EMMHJV5XTAZSM4MWEZTN')
lab=root/'.v/h'
env=dict(os.environ, TMUX_TMPDIR=str(lab/'tmux'))
for task in ('approved','restricted'):
    gen=subprocess.check_output([str(root/'bin/fm-busy-event.sh'),'arm',str(lab/'state'),task],text=True).strip()
    command=shlex.join(['bash',str(root/'bin/fm-busy-event.sh'),'apply',str(lab/'state'),task,'idle','--gen',gen,'--source','claude-hook','--event','Stop'])
    settings=lab/f'{task}-settings.json'
    settings.write_text(json.dumps({'hooks':{'Stop':[{'hooks':[{'type':'command','command':command}]}]}}))
    args=['claude','-p','Reply READY only. Do not use tools or access any files.','--setting-sources','','--settings',str(settings),'--system-prompt','You are a disposable validation worker. Return the requested acknowledgement without using tools.','--tools','','--model','sonnet','--output-format','json']
    script=lab/f'{task}-worker.sh'
    script.write_text('#!/usr/bin/env bash\n'+shlex.join(args)+' > '+shlex.quote(str(lab/f'{task}-worker-result.json'))+' 2> '+shlex.quote(str(lab/f'{task}-worker-errors.log'))+'\nexec bash --noprofile --norc\n')
    with (lab/f'state/{task}.meta').open('a') as f:f.write(f'window=primary:fm-{task}\nbackend=tmux\nharness=claude\n')
    subprocess.run(['tmux','-L','fm-lab','new-window','-d','-t','primary','-n',f'fm-{task}','-c',str(root),'bash '+str(script)],env=env,check=True)
