import json, os, pathlib, subprocess
R=pathlib.Path('/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M73G5Q90CZZH9110408J88VH')
L=R/'.l'
E=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M73G5Q90CZZH9110408J88VH')
env={k:v for k,v in os.environ.items() if not k.startswith(('FM_','TASKS_AXI_','NO_MISTAKES_','GIT_'))}
env.update(FM_HOME=str(L),TMPDIR=str(R/'.ahoy-validation-tmp'),GIT_CEILING_DIRECTORIES=str(R))
(E/'live-moving-and-call-checkpoint.json').write_bytes((L/'state/ahoy-last.json').read_bytes())
(L/'state/ahoy-worker.meta').unlink()
(L/'answer.txt').write_text('Use the direct route.\n')
commands=[
    [str(R/'bin/fm-captain-hold.sh'),'answer','live-call','--decision-file',str(L/'answer.txt')],
    [str(R/'bin/fm-queue.py'),'done','ahoy-worker','--file',str(L/'data/backlog.md')],
]
for c in commands:
    p=subprocess.run(c,env=env,text=True,capture_output=True,cwd=R,check=True)
    print(p.stdout)
