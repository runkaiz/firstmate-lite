import os, subprocess, tempfile, shutil
from pathlib import Path
root=Path.cwd()
lab=Path(tempfile.mkdtemp(prefix="fastmode-manual.",dir=root/".fastmode-test-tmp"))
env={k:v for k,v in os.environ.items() if not(k.startswith("FM_") and (k.endswith("_OVERRIDE") or k=="FM_HOME"))}
home=lab/"home with spaces"
env["FM_HOME"]=str(home)
def run(args=(), expected="off", code=0, settings=None):
    e=env.copy(); e.update(settings or {})
    result=subprocess.run(["bash",str(root/"bin/fm-fastmode.sh"),*args],env=e,text=True,capture_output=True)
    print("$ bash bin/fm-fastmode.sh"+(" "+" ".join(args) if args else ""))
    print(result.stdout+result.stderr,end="")
    print("exit:",result.returncode)
    assert result.returncode==code
    if code==0: assert result.stdout=="WORKER FAST MODE: "+expected+"\n"
    return result
try:
    print("ISOLATED HOME: home with spaces; no existing config")
    run(); run(["status"])
    assert not home.exists()
    print("Status left the absent home absent.")
    run(["on"],"on")
    flag=home/"config/worker-fast-mode"
    assert flag.is_file()
    print("Persisted presence file: home with spaces/config/worker-fast-mode")
    flag.write_text("existing preference contents\n")
    before=flag.stat().st_mtime_ns
    run(["on"],"on"); run([],"on"); run(["status"],"on")
    assert flag.read_text()=="existing preference contents\n" and flag.stat().st_mtime_ns==before
    print("Repeated on and status preserved existing flag bytes and mtime.")
    for args in (["maybe"],["on","gpt-6"],["off","gpt-6"],["status","gpt-6"]):
        run(args,code=2)
        assert flag.read_text()=="existing preference contents\n" and flag.stat().st_mtime_ns==before
    print("Every invalid command preserved the enabled preference.")
    run(["off"]); run(["off"]); run(["status"])
    assert not flag.exists()
    print("Repeated off removed only the presence file.")
    override=lab/"config override with spaces"
    run(["on"],"on",settings={"FM_CONFIG_OVERRIDE":str(override)})
    assert (override/"worker-fast-mode").is_file() and not flag.exists()
    run([],"on",settings={"FM_CONFIG_OVERRIDE":str(override)})
    run(["off"],settings={"FM_CONFIG_OVERRIDE":str(override)})
    assert not (override/"worker-fast-mode").exists()
    print("Config override took precedence over FM_HOME and affected only its own flag.")
    env.pop("FM_HOME")
    env["FM_ROOT_OVERRIDE"]=str(lab/"root fallback")
    run(["on"],"on"); run(["status"],"on"); run(["off"])
    assert not (lab/"root fallback/config/worker-fast-mode").exists()
    print("Root fallback on/status/off also persisted and removed its own flag.")
    print("ALL DIRECT PRODUCT SCENARIOS PASSED")
finally:
    shutil.rmtree(lab)
    print("Disposable manual home removed.")
