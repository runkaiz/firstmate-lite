import os,subprocess,time,pathlib,shutil
root=pathlib.Path.cwd(); scratch=root/'.calm-validation'; evidence=pathlib.Path('/home/runkai/.no-mistakes/evidence/01M61Q2TFMG98XD2R55EMBXAH4')
shutil.copyfile(evidence/'calm-focused-tests.log',evidence/'calm-chrome-temp-attempt.log')
env=os.environ.copy();env.update(TMPDIR=str(scratch/'tmp'),FM_TEST_TMPDIR=str(scratch/'tmp'),TMUX_TMPDIR='/tmp',FM_PI_PACKAGE_DIR='/var/home/runkai/.pi/agent/install/releases/1.4.0/node_modules/@earendil-works/pi-coding-agent',FM_CHROME_BIN=str(scratch/'chrome-private'))
with (evidence/'calm-focused-tests.log').open('w') as out:
 p=subprocess.Popen(['bin/fm-test-run.sh','tests/fm-calm-pi-extension.test.sh'],env=env,stdout=out,stderr=subprocess.STDOUT)
 seen={}
 while p.poll() is None:
  for fixture in (scratch/'tmp').glob('fm-calm-pi-extension.*'):
   for f in fixture.iterdir():
    if f.suffix in ['.txt','.html','.jsonl','.err'] and f.is_file():
     try:
      stamp=f.stat().st_mtime_ns
      if seen.get(str(f))!=stamp:
       shutil.copyfile(f,evidence/f.name);seen[str(f)]=stamp
     except FileNotFoundError: pass
  time.sleep(.08)
 print('EXIT',p.returncode)
 print((evidence/'calm-focused-tests.log').read_text()[-5500:])
