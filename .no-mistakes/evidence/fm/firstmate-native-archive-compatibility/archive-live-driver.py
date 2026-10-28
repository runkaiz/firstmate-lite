import os, sys, runpy, tempfile, unittest, json, threading, hashlib
from pathlib import Path
ROOT = Path("/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F")
EVIDENCE = Path(__file__).parent
names = [
"test_legacy_dated_archive_sections_are_completed_history",
"test_archive_lookup_reopen_and_identity_reservation",
"test_reopened_single_record_keeps_identity_and_appends_completion",
"test_archived_edits_append_idempotent_revisions",
"test_late_evidence_preserves_legacy_completion_verbs",
"test_late_evidence_after_linked_recompletion_recovers_once",
"test_single_record_continuation_rm_and_reopen_recover",
"test_repeated_archived_identity_is_refused_not_guessed",
"test_explicit_history_link_resolves_latest_and_reopen_continues_it",
"test_bad_history_links_stay_ambiguous",
"test_concurrent_history_links_record_once",
"test_active_record_beside_archived_history_stays_refused",
"test_legacy_history_survives_crash_recovery_and_concurrent_writers",
"test_cross_queue_history_moves_refuse_without_changing_either_store",
"test_active_archive_conflict_fails_without_discarding",
"test_compatibility_check_and_backup_never_rewrite",
]
module = runpy.run_path(str(ROOT / "tests/fm-queue.test.py"), run_name="archive_live_import")
Tests = module["QueueTests"]
original_call = Tests.call
lock = threading.Lock()
def capture(self, *args, **kwargs):
    result = original_call(self, *args, **kwargs)
    entry = {"command": [str(module["CLI"]), *args, "--file", str(kwargs.get("path") or self.file)], "environment_overrides": kwargs.get("extra_env", {}), "exit_code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
    with lock, (EVIDENCE / (self._testMethodName + ".jsonl")).open("a") as out:
        out.write(json.dumps(entry) + "\n")
    return result
def persist(self):
    files = {}
    for p in self.home.rglob("*"):
        if p.is_file() and p.suffix in (".md", ".json", ".toml"):
            raw=p.read_bytes()
            files[str(p.relative_to(self.home))] = {"sha256": hashlib.sha256(raw).hexdigest(), "content": raw.decode()}
    (EVIDENCE / (self._testMethodName + "-state.json")).write_text(json.dumps(files, indent=2))
Tests.call = capture
Tests.tearDown = persist
with tempfile.TemporaryDirectory(prefix=".archive-live-", dir=ROOT) as tmp:
    os.environ["FM_QUEUE_TEST_ROOT"] = tmp
    with (EVIDENCE / "archive-targeted-results.txt").open("w") as output:
        result = unittest.TextTestRunner(stream=output, verbosity=2).run(unittest.TestSuite(Tests(n) for n in names))
    print((EVIDENCE / "archive-targeted-results.txt").read_text())
    sys.exit(0 if result.wasSuccessful() else 1)
