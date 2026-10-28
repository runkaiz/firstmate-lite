"""Product CLI durability walkthrough using isolated data and real processes."""
import concurrent.futures, json, os, pathlib, shlex, shutil, subprocess, tempfile
ROOT=pathlib.Path.cwd()
EVIDENCE=pathlib.Path(__file__).parent
home=pathlib.Path(tempfile.mkdtemp(prefix="durability-", dir=ROOT/".test-phase-tmp"))
env={k:v for k,v in os.environ.items() if not k.startswith(("FM_", "TASKS_AXI_", "TMUX"))}
env.update(HOME=str(home), FM_HOME=str(home), TMPDIR=str(ROOT/".test-phase-tmp"))
log=(EVIDENCE/"durability-walkthrough.log").open("w")
def run(*args, codes=(0,), extra=None):
    command=[str(ROOT/"bin/fm-queue.sh"), *map(str,args)]
    p=subprocess.run(command, cwd=ROOT, env=dict(env, **(extra or {})), capture_output=True, text=True, timeout=40)
    log.write("$ fm-queue.sh "+shlex.join(list(map(str,args)))+"\n"+p.stdout+p.stderr+f"[exit {p.returncode}]\n")
    log.flush()
    assert p.returncode in codes, p.stderr
    return p.stdout
try:
    (home/"data").mkdir()
    (home/".tasks.toml").write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
    queue=home/"data/backlog.md"
    archive=home/"data/done-archive.md"
    journal=home/"data/backlog.md.transaction"
    log.write("=== Independent simultaneous writers and duplicate admission ===\n")
    with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
        list(pool.map(lambda i:run("add",f"work-{i}","Accepted work"),range(12)))
    assert len(json.loads(run("list","--json"))["tasks"])==12
    def race(i):
        p=subprocess.run([str(ROOT/"bin/fm-queue.sh"),"add","contended","Exactly one"],cwd=ROOT,env=env,capture_output=True,text=True,timeout=40)
        return p.returncode,p.stdout,p.stderr
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results=list(pool.map(race,range(4)))
    for rc,out,err in results: log.write(f"concurrent add contended: exit {rc}\n{out}{err}")
    assert sum(rc==0 for rc,_,_ in results)==1
    assert len(json.loads(run("list","--json"))["tasks"])==13
    log.write("=== Process interruption after one archive write, then ordinary read recovery ===\n")
    run("done","contended","--report","data/contended/report.md","--no-prune")
    run("prune","--keep","0",codes=(91,),extra={"FM_QUEUE_TEST_CRASH_AFTER_WRITES":"1"})
    assert journal.exists()
    log.write("Pending durable journal exists after process exit 91.\n")
    for _ in range(2):
        record=json.loads(run("show","contended","--json"))["task"]
        assert record["archived"] and "data/contended/report.md" in record["links"]
    assert not journal.exists()
    run("add","contended","Cannot reuse",codes=(1,))
    log.write("Recovery consumed journal once and retained original archived identity/link.\n")
    log.write("=== Corrupt rows, metadata, duplicate IDs and recovery data refuse mutation ===\n")
    saved=queue.read_bytes()
    for bad in ["## Queued\n- [ ] invalid row\n", "## Queued\n- [ ] invalid - Work (hold: choose (north)) (hold-kind: captain)\n", "## Queued\n- [ ] contended - Duplicate archive identity\n"]:
        queue.write_text(bad)
        before={p.name:p.read_bytes() for p in (home/"data").iterdir() if p.is_file()}
        run("add","new","Must refuse",codes=(1,))
        assert before=={p.name:p.read_bytes() for p in (home/"data").iterdir() if p.is_file()}
    queue.write_bytes(saved)
    journal.write_text('{"version":1,"roots":"not a list"}')
    run("list",codes=(1,))
    assert journal.read_text()=='{"version":1,"roots":"not a list"}'
    journal.unlink()
    log.write("Refusals left persisted input unchanged.\n")
    log.write("=== Removing unfinished work never completes a prerequisite ===\n")
    run("add","dependent","Waiting","--blocked-by","work-0")
    run("rm","work-0",codes=(1,))
    assert "dependent" not in [t["id"] for t in json.loads(run("ready","--json"))["tasks"]]
    print("Concurrent writes, process-interruption recovery, corruption refusal, and unfinished-removal boundaries passed.")
finally:
    shutil.rmtree(home)
    log.write("Disposable data removed.\n")
    log.close()
