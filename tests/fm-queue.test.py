"""Behavioral native queue tests. No external tasks-axi executable is used."""

import concurrent.futures
import datetime
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


ROOT = Path(__file__).resolve().parent.parent
CLI = ROOT / "bin/fm-queue.py"
TODAY = datetime.datetime.now(datetime.timezone.utc).date().isoformat()
# Synthetic archive in the legacy writer's append shape: each prune appended
# "\n## Archived <date>\n" plus the pruned rows' original lines.
LEGACY_ARCHIVE = (
    "\n## Archived 2026-01-05\n"
    "- [x] alpha - First delivery - https://example.test/project/pull/1 (repo: project) (kind: ship) (merged 2026-01-04)\n"
    "  Accepted first scope (kind: not-metadata)\n"
    "\n"
    "  ## Intent\n"
    "  - [x] lookalike - not a row (done 2026-01-01)\n"
    "\n## Archived 2026-01-07\n"
    "- [x] beta - Prerequisite - data/beta/report.md (repo: project) (kind: scout) (reported 2026-01-06)\n"
    "\n## Archived 2026-01-07\n"
    "- [x] gamma - Unrelated (done 2026-01-07)\n"
    "\n## Archived 2026-01-09\n"
    "- [x] alpha - Follow-up delivery (repo: project) (kind: task) (done 2026-01-09)\n"
    "  Follow-up scope\n"
)
GAMMA = "- [x] gamma - Unrelated (done 2026-01-07)\n\n"


class QueueTests(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory(dir=os.environ.get("FM_QUEUE_TEST_ROOT"))
        self.addCleanup(self.tmp.cleanup)
        self.home = Path(self.tmp.name)
        (self.home / "data").mkdir()
        (self.home / ".tasks.toml").write_text('backend = "markdown"\n[markdown]\npath = "data/backlog.md"\narchive = "data/done-archive.md"\ndone_keep = 100\n')
        self.file = self.home / "data/backlog.md"
        self.env = {key: value for key, value in os.environ.items() if not key.startswith(("FM_QUEUE_", "TASKS_AXI_"))}
        self.env["HOME"] = str(self.home)

    def call(self, *args, good=True, path=None, extra_env=None):
        env = dict(self.env, **(extra_env or {}))
        result = subprocess.run([str(CLI), *args, "--file", str(path or self.file)], cwd=self.home, env=env, text=True, capture_output=True, timeout=20)
        if good:
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        elif good is not None:
            self.assertNotEqual(result.returncode, 0, result.stdout)
        return result

    def task(self, identifier):
        return json.loads(self.call("show", identifier, "--json").stdout)["task"]

    def ready(self):
        return [task["id"] for task in json.loads(self.call("ready", "--json").stdout)["tasks"]]

    def history(self, identifier):
        return json.loads(self.call("show", identifier, "--history", "--json").stdout)

    def legacy(self, active="## In flight\n\n## Queued\n\n## Done\n", archive=LEGACY_ARCHIVE):
        self.archive = self.home / "data/done-archive.md"
        self.file.write_text(active)
        self.archive.write_text(archive)
        return self.file.read_bytes(), self.archive.read_bytes()

    def test_user_backend_refusal_preserves_existing_and_absent_queues(self):
        self.call("add", "stable", "Existing", "--body", "Original intent")
        self.call("update", "stable", "--body", "Revised intent")
        self.call("add", "archived", "Delivered")
        self.call("done", "archived")
        self.call("prune", "--keep", "0")
        (self.home / ".tasks.toml").unlink()
        global_config = self.home / ".tasks-axi/config.toml"
        global_config.parent.mkdir()
        global_config.write_text('backend = "beads"\n[beads]\npassword = "private-value"\n')
        env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT))
        commands = []
        for entry in ([str(CLI)], ["bash", str(ROOT / "bin/fm-queue.sh")]):
            commands.extend([entry + ["list"], entry + ["add", "new", "New"],
                             entry + ["hold", "stable", "--reason", "Choose"]])
        for identifier in ("stable", "new-question"):
            commands.append(["bash", str(ROOT / "bin/fm-captain-hold.sh"), "hold", identifier,
                             "--title", "Question", "--reason", "Choose scope"])
        for existing in (True, False):
            if not existing:
                for path in (self.home / "data").iterdir():
                    path.unlink()
            before = {str(path.relative_to(self.home)): path.read_bytes()
                      for path in self.home.rglob("*") if path.is_file()}
            for command in commands:
                with self.subTest(existing=existing, command=command):
                    result = subprocess.run(command, cwd=self.home, env=env, text=True, capture_output=True)
                    self.assertNotEqual(result.returncode, 0, result.stdout)
                    self.assertIn("Markdown only", result.stderr)
                    self.assertNotIn("private-value", result.stdout + result.stderr)
                    after = {str(path.relative_to(self.home)): path.read_bytes()
                             for path in self.home.rglob("*") if path.is_file()}
                    self.assertEqual(after, before)

    def test_malformed_or_unreadable_effective_backend_refuses(self):
        project_config = self.home / ".tasks.toml"
        global_config = self.home / ".tasks-axi/config.toml"
        global_config.parent.mkdir()
        env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT))
        probe = '. "$1/bin/fm-tasks-axi-lib.sh"; "$2" "$3"'
        commands = [[str(CLI), "add", "new", "Task"],
                    ["bash", str(ROOT / "bin/fm-queue.sh"), "list"],
                    ["bash", str(ROOT / "bin/fm-captain-hold.sh"), "hold", "new", "--title", "Question", "--reason", "Choose"]]
        for resolver in ("fm_tasks_axi_backend", "fm_tasks_axi_backend_resolve"):
            commands.append(["bash", "-c", probe, "_", str(ROOT), resolver, str(self.home)])
        for config in (project_config, global_config):
            project_config.unlink(missing_ok=True)
            for case in ("unquoted", "duplicate", "invalid-utf8", "directory", "dangling", "permissions"):
                if case == "permissions" and os.geteuid() == 0:
                    continue
                with self.subTest(config=config, case=case):
                    if case == "directory":
                        config.mkdir()
                    elif case == "dangling":
                        config.symlink_to("missing-config")
                    else:
                        content = {"unquoted": b'backend = secret-invalid-value\n',
                                   "duplicate": b'backend = "markdown"\nbackend = "beads"\n',
                                   "invalid-utf8": b'backend = "\xff"\n',
                                   "permissions": b'backend = "beads"\n'}[case]
                        config.write_bytes(content)
                        if case == "permissions":
                            config.chmod(0)
                    try:
                        for command in commands:
                            result = subprocess.run(command, cwd=self.home, env=env, text=True, capture_output=True)
                            self.assertNotEqual(result.returncode, 0, result.stdout)
                            self.assertIn("configuration" if case in ("invalid-utf8", "directory", "dangling", "permissions") else "selection", result.stderr)
                            self.assertNotIn("secret-invalid-value", result.stdout + result.stderr)
                            self.assertFalse(self.file.exists())
                            self.assertEqual(list((self.home / "data").iterdir()), [])
                    finally:
                        if case == "directory":
                            config.rmdir()
                        else:
                            if case == "permissions":
                                config.chmod(0o600)
                            config.unlink()

    def test_backend_selection_precedence_and_native_defaults(self):
        project_config = self.home / ".tasks.toml"
        global_config = self.home / ".tasks-axi/config.toml"
        global_config.parent.mkdir()
        probe = '. "$1/bin/fm-tasks-axi-lib.sh"; "$2" "$3"'
        cases = [
            (None, None, {}),
            ('[markdown]\npath = "data/backlog.md"\n', 'backend = "markdown"\n[markdown]\npath = "ignored/backlog.md"\n', {}),
            ('backend = "markdown"\n', 'backend = "beads"\n', {}),
            ('backend = "markdown"\n', 'backend = invalid\n', {}),
            ('backend = "beads"\n', 'backend = "beads"\n', {"TASKS_AXI_BACKEND": "markdown"}),
            (None, 'backend = "beads"\n', {"TASKS_AXI_BACKEND": "markdown"}),
            (None, 'backend = invalid\n', {"FM_QUEUE_BACKEND": "markdown", "TASKS_AXI_BACKEND": "beads"}),
        ]
        for project, legacy, overrides in cases:
            with self.subTest(project=project, legacy=legacy, overrides=overrides):
                for path, content in ((project_config, project), (global_config, legacy)):
                    if content is None:
                        path.unlink(missing_ok=True)
                    else:
                        path.write_text(content)
                env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT), **overrides)
                for entry in ([str(CLI)], ["bash", str(ROOT / "bin/fm-queue.sh")]):
                    result = subprocess.run(entry + ["list", "--json"], cwd=self.home, env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(json.loads(result.stdout)["tasks"], [])
                for resolver in ("fm_tasks_axi_backend", "fm_tasks_axi_backend_resolve"):
                    result = subprocess.run(["bash", "-c", probe, "_", str(ROOT), resolver, str(self.home)],
                                            env=env, text=True, capture_output=True)
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stdout.strip(), "markdown")
        self.call("add", "explicit", "Explicit choice", "--backend", "markdown",
                  extra_env={"FM_QUEUE_BACKEND": "beads", "TASKS_AXI_BACKEND": "beads"})
        self.assertFalse((self.home / "ignored").exists())

    def test_wrapper_cli_backend_precedence(self):
        self.call("add", "stable", "Existing")
        before = self.file.read_bytes()
        for wrapper in ("fm-queue.sh", "fm-tasks-axi.sh"):
            for variable in ("FM_QUEUE_BACKEND", "TASKS_AXI_BACKEND"):
                env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT),
                           **{variable: "beads"})
                for flags in (["--backend", "markdown"], ["--backend=markdown"],
                              ["--backend", "beads", "--backend", "markdown"],
                              ["--body=--backend=beads", "--backend", "markdown"]):
                    with self.subTest(wrapper=wrapper, variable=variable, flags=flags):
                        result = subprocess.run(["bash", str(ROOT / "bin" / wrapper), "list", "--json", *flags],
                                                cwd=self.home, env=env, text=True, capture_output=True, timeout=20)
                        self.assertEqual(result.returncode, 0, result.stderr)
                        self.assertEqual([task["id"] for task in json.loads(result.stdout)["tasks"]], ["stable"])
                for flags, source in (([], variable), (["--body=--backend=markdown"], variable),
                                      (["--backend", "markdown", "--backend=beads"], "--backend")):
                    with self.subTest(wrapper=wrapper, variable=variable, flags=flags):
                        result = subprocess.run(["bash", str(ROOT / "bin" / wrapper), "list", *flags],
                                                cwd=self.home, env=env, text=True, capture_output=True, timeout=20)
                        self.assertNotEqual(result.returncode, 0)
                        self.assertIn(source, result.stderr)
                        self.assertIn("Markdown only", result.stderr)
                self.assertEqual(self.file.read_bytes(), before)

    def test_ready_and_start_agree_for_ordinary_kinds(self):
        self.call("add", "followup", "Accepted follow-up", "--kind", "public-followup")
        self.assertEqual(self.ready(), ["followup"])
        self.call("add", "prerequisite", "Required work")
        self.call("block", "followup", "--by", "prerequisite")
        self.assertNotIn("followup", self.ready())
        self.call("start", "followup", good=False)
        self.call("done", "prerequisite")
        self.call("hold", "followup", "--kind", "captain", "--reason", "Choose scope")
        self.assertNotIn("followup", self.ready())
        self.call("start", "followup", good=False)
        self.call("unhold", "followup")
        self.assertEqual(self.ready(), ["followup"])
        self.call("start", "followup")
        self.assertEqual(self.task("followup")["state"], "in_flight")

    def test_removed_commands_and_flags_refuse_without_rewriting(self):
        self.file.write_text("## Queued\n- [ ] stable - Original (kind: ship, repo: project)\n\n  Accepted intent\n")
        archive = self.file.parent / "done-archive.md"
        archive.write_text("## Done\n- [x] old - Delivered (done 2026-01-01)\n\n  Historical intent\n")
        notes = self.file.parent / "note-archive.md"
        notes.write_text("Existing body history\n")
        before = [path.read_bytes() for path in (self.file, archive, notes)]
        self.call("render", good=False)
        for verb in ("add", "create"):
            for flags in (("--mint",), ("--prefix", "task"), ("--queue",), ("--queue", "--start")):
                self.call(verb, "new", "New task", *flags, good=False)
        self.assertEqual([path.read_bytes() for path in (self.file, archive, notes)], before)
        self.call("create", "new", "New task")
        self.assertEqual(self.task("new")["state"], "queued")

    def test_unicode_body_survives_mutations_history_and_archive(self):
        body = "\nFirst\u0085second\u2028third\u2029fourth\n  Indented 雪 🧭\n\n"
        self.call("add", "unicode", "Unicode intent", "--body", body)
        self.assertEqual(self.task("unicode")["body"], body)
        self.call("hold", "unicode", "--kind", "captain", "--reason", "Choose scope")
        self.assertEqual(self.task("unicode")["body"], body)
        self.call("unhold", "unicode")
        self.call("start", "unicode")
        note = "Completed\u2028with evidence"
        self.call("done", "unicode", "--note", note, "--pr", "https://example.test/pull/1")
        expected = body + "\n\n" + note
        self.assertEqual(self.task("unicode")["body"], expected)
        self.call("prune", "--keep", "0")
        self.assertEqual(self.task("unicode")["body"], expected)
        self.call("reopen", "unicode")
        self.assertEqual(self.task("unicode")["body"], expected)
        replacement = "Revised\u2028scope\nNext\u0085step\u2029雪"
        body_file = self.home / "intent.txt"
        body_file.write_text(replacement)
        self.call("edit", "unicode", "--body-file", str(body_file))
        self.assertEqual(self.task("unicode")["body"], replacement)
        history = (self.home / "data/note-archive.md").read_text()
        self.assertIn("First\u0085second\u2028third\u2029fourth", history)
        self.assertIn(note, history)
        target = self.home / "other/data/backlog.md"
        self.call("mv", "unicode", "--to", str(target), good=False)
        self.assertEqual(self.task("unicode")["body"], replacement)
        self.assertEqual(len(self.history("unicode")["records"]), 2)
        self.call("add", "movable", "Unicode intent", "--body", replacement, "--pr", "https://example.test/pull/1")
        self.call("mv", "movable", "--to", str(target))
        moved = json.loads(self.call("show", "movable", "--json", path=target).stdout)["task"]
        self.assertEqual(moved["body"], replacement)
        self.assertEqual(moved["links"], ["https://example.test/pull/1"])

    def test_ambiguous_content_is_refused_before_persistence(self):
        self.call("add", "stable", "Original title", "--body", "Accepted intent")
        before = self.file.read_bytes()
        for command in (("add", "ambiguous", "Compare with - https://example.test/x"),
                        ("edit", "stable", "--title", "Compare with - https://example.test/x"),
                        ("done", "stable", "--report", "unrecognized-report.md")):
            result = self.call(*command, good=False)
            self.assertIn("round-trip", result.stderr)
            self.assertEqual(self.file.read_bytes(), before)
            self.assertFalse((self.home / "data/note-archive.md").exists())
            self.assertFalse(Path(str(self.file) + ".transaction").exists())
        self.assertEqual(self.task("stable")["links"], [])
        self.call("update", "stable", "--title", "Revised title")
        self.assertEqual(self.task("stable")["title"], "Revised title")

    def test_retained_context_requires_authorization_for_kind_changes(self):
        for kind in ("idea", "outcome"):
            self.call("add", kind, "Retained context", "--kind", kind)
            for verb in ("update", "edit"):
                for new_kind in ("ship", "scout", "task", "idea", "outcome"):
                    if new_kind == kind:
                        continue
                    before = self.file.read_bytes()
                    self.call(verb, kind, "--kind", new_kind, good=False)
                    self.assertEqual(self.file.read_bytes(), before)
            for hold_kind in (None, "future", "captain", "external", "load"):
                flags = ["--kind", hold_kind] if hold_kind else []
                before = self.file.read_bytes()
                self.call("hold", kind, "--reason", "Revisit later", *flags, good=False)
                self.assertEqual(self.file.read_bytes(), before)
            self.call("hold", kind, "--kind", "parked", "--reason", "Retain context", "--until", "2000-01-01")
            self.call("edit", kind, "--kind", kind, "--body", "Retained scope")
            self.call("unhold", kind, good=False)
            self.call("start", kind, good=False)
            self.assertNotIn(kind, self.ready())
        self.call("add", "ordinary", "Accepted task", "--kind", "ship")
        for verb in ("update", "edit"):
            for kind in ("idea", "outcome"):
                self.call(verb, "ordinary", "--kind", kind, good=False)
        self.call("update", "ordinary", "--kind", "scout")
        self.assertEqual(self.task("ordinary")["kind"], "scout")
        self.call("authorize", "idea", "--kind", "ship", "--body", "Accepted instruction")
        self.assertIn("idea", self.ready())
        self.assertIsNone(self.task("idea")["hold_kind"])
        self.assertIn("Retained scope", (self.home / "data/note-archive.md").read_text())
        self.call("authorize", "outcome", "--body", "Cannot execute an umbrella", good=False)
        self.assertNotIn("outcome", self.ready())

    def test_relative_backup_destination_uses_caller_directory(self):
        self.call("add", "stable", "Original", "--body", "Accepted scope")
        caller = self.home / "caller"
        caller.mkdir()
        env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT))
        before = self.file.read_bytes()
        for entry in ("fm-queue.sh", "fm-tasks-axi.sh"):
            for joined in (False, True):
                name = entry + ("-joined" if joined else "-separate")
                flags = ["--backup-dir=./" + name] if joined else ["--backup-dir", "./" + name]
                command = ["bash", str(ROOT / "bin" / entry), "migrate", *flags]
                result = subprocess.run(command, cwd=caller, env=env, text=True, capture_output=True)
                self.assertEqual(result.returncode, 0, result.stderr)
                self.assertEqual((caller / name / "0-backlog.md").read_bytes(), before)
                self.assertFalse((self.home / name).exists())
                repeated = subprocess.run(command, cwd=caller, env=env, text=True, capture_output=True)
                self.assertNotEqual(repeated.returncode, 0)
                self.assertEqual((caller / name / "0-backlog.md").read_bytes(), before)
        self.assertEqual(self.file.read_bytes(), before)

    def test_symlinked_user_selection_and_named_refusal_sources(self):
        project = self.home / ".tasks.toml"
        project.write_text('[markdown]\npath = "data/backlog.md"\n')
        legacy = self.home / ".tasks-axi/config.toml"
        legacy.parent.mkdir()
        target = self.home / "dotfiles/tasks.toml"
        target.parent.mkdir()
        legacy.symlink_to(target)
        target.write_text('backend = "markdown"\n')
        env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT))
        probe = '. "$1/bin/fm-tasks-axi-lib.sh"; "$2" "$3"'
        commands = [[str(CLI), "list"], [str(CLI), "snapshot"],
                    ["bash", str(ROOT / "bin/fm-queue.sh"), "list"],
                    ["bash", str(ROOT / "bin/fm-tasks-axi.sh"), "list"]]
        for resolver in ("fm_tasks_axi_backend", "fm_tasks_axi_backend_resolve"):
            commands.append(["bash", "-c", probe, "_", str(ROOT), resolver, str(self.home)])
        for command in commands:
            result = subprocess.run(command, cwd=self.home, env=env, text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
        for source in (str(legacy), str(project), "TASKS_AXI_BACKEND", "FM_QUEUE_BACKEND", "--backend"):
            target.write_text('backend = "private-backend-value"\n[beads]\npassword = "private-password"\n')
            project.write_text('backend = "private-backend-value"\n' if source == str(project) else '[markdown]\npath = "data/backlog.md"\n')
            selected_env = dict(env)
            if source in ("FM_QUEUE_BACKEND", "TASKS_AXI_BACKEND"):
                selected_env[source] = "private-backend-value"
            selected_commands = [[str(CLI), "list", "--backend", "private-backend-value"]] if source == "--backend" else commands
            for command in selected_commands:
                result = subprocess.run(command, cwd=self.home, env=selected_env, text=True, capture_output=True)
                self.assertNotEqual(result.returncode, 0)
                self.assertIn(source, result.stderr)
                self.assertIn("Markdown only", result.stderr)
                self.assertNotIn("private-backend-value", result.stdout + result.stderr)
                self.assertNotIn("private-password", result.stdout + result.stderr)
        for case in ("invalid-utf8", "directory", "fifo", "dangling", "permissions"):
            if case == "permissions" and os.geteuid() == 0:
                continue
            target.unlink(missing_ok=True)
            if case == "directory":
                target.mkdir()
            elif case == "fifo":
                os.mkfifo(target)
            elif case != "dangling":
                target.write_bytes(b'\xff' if case == "invalid-utf8" else b'backend = "markdown"\n')
                if case == "permissions":
                    target.chmod(0)
            try:
                for command in commands:
                    result = subprocess.run(command, cwd=self.home, env=env, text=True, capture_output=True, timeout=20)
                    self.assertNotEqual(result.returncode, 0)
                    self.assertIn(str(legacy), result.stderr)
                    self.assertIn("cannot be read", result.stderr)
                    self.assertFalse(self.file.exists())
            finally:
                if case == "directory":
                    target.rmdir()
                elif case == "permissions":
                    target.chmod(0o600)
        project.write_text('backend = "markdown"\n')
        target.write_text('backend = "beads"\n')
        self.call("add", "override", "Explicit supported project")
        self.assertTrue(legacy.is_symlink())
        self.assertEqual(target.read_text(), 'backend = "beads"\n')

    def test_capture_authorization_and_restart(self):
        self.call("add", "outcome", "Outcome", "--outcome", "--body", "Members: idea, accepted")
        self.call("add", "idea", "Idea", "--idea", "--priority", "0")
        self.call("add", "accepted", "Accepted step", "--body", "Accepted scope: first step")
        self.assertEqual(self.ready(), ["accepted"])
        self.assertEqual(self.task("idea")["hold_kind"], "parked")
        self.assertIsNone(self.task("idea")["hold_until"])
        self.call("unhold", "idea", good=False)
        self.call("authorize", "idea", good=False)
        self.call("authorize", "idea", "--body", "Actual accepted instruction and scope", "--kind", "ship")
        self.assertEqual(self.ready(), ["idea", "accepted"])
        self.assertNotIn("outcome", self.ready())

    def test_dependency_completion_with_archived_prerequisite(self):
        self.call("add", "a", "First")
        self.call("add", "b", "Dependent", "--blocked-by", "a")
        self.assertEqual(self.ready(), ["a"])
        self.call("start", "b", good=False)
        self.call("start", "a")
        self.call("close", "a", "--report", "data/a/report.md", "--note", "local main", "--no-prune")
        self.call("prune", "--keep", "0")
        self.assertEqual(self.ready(), ["b"])
        self.assertTrue(self.task("a")["archived"])

    def test_archive_lookup_reopen_and_identity_reservation(self):
        self.call("add", "stable", "Original", "--body", "Accepted original intent")
        self.call("hold", "stable", "--kind", "captain", "--reason", "Choose release", "--until", "2099-01-01")
        self.call("update", "stable", "--body", "Answer: use existing release")
        self.call("done", "stable", "--pr", "https://example.test/project/pull/1")
        self.call("prune", "--keep", "0")
        before = self.task("stable")
        self.assertTrue(before["archived"])
        self.assertEqual(before["hold_reason"], "Choose release")
        self.assertIn("https://example.test/project/pull/1", before["links"])
        self.assertIn("already exists", self.call("add", "stable", "Replacement", good=False).stderr)
        self.call("reopen", "stable")
        after = self.task("stable")
        self.assertFalse(after["archived"])
        self.assertEqual(after["state"], "queued")
        self.assertEqual(after["body"], before["body"])
        self.assertEqual(after["links"], before["links"])
        self.assertNotIn("stable", self.ready())
        self.assertIn("Accepted original intent", (self.home / "data/note-archive.md").read_text())

    def test_active_archive_conflict_fails_without_discarding(self):
        self.call("add", "same", "Active")
        archive = self.home / "data/done-archive.md"
        archive.write_text("## Done\n- [x] same - Historical (done 2026-01-01)\n  Prior answer\n")
        before = self.file.read_bytes(), archive.read_bytes()
        self.call("show", "same", good=False)
        self.call("add", "unrelated", "Do not guess", good=False)
        self.assertEqual(before, (self.file.read_bytes(), archive.read_bytes()))

    def test_legacy_dated_archive_sections_are_completed_history(self):
        active = "## In flight\n\n## Queued\n- [ ] next - Follow-on (repo: project) blocked-by: beta\n- [ ] later - Uses alpha blocked-by: alpha\n\n## Done\n"
        before = self.legacy(active)
        check = json.loads(self.call("migrate", "--dry-run").stdout)
        self.assertEqual((check["records"], check["identities"], check["ambiguous_histories"]), (6, 5, ["alpha"]))
        backup = self.home / "backup"
        self.call("migrate", "--backup-dir", str(backup))
        self.assertEqual(((backup / "0-backlog.md").read_bytes(), (backup / "1-done-archive.md").read_bytes()), before)
        hashes = {entry["backup"]: entry["sha256"] for entry in json.loads((backup / "manifest.json").read_text())}
        self.assertEqual(hashes["1-done-archive.md"], hashlib.sha256(before[1]).hexdigest())
        beta = self.task("beta")
        self.assertEqual((beta["links"], beta["closed"], beta["kind"], beta["archived"]), (["data/beta/report.md"], "2026-01-06", "scout", True))
        self.assertEqual(self.task("gamma")["closed"], "2026-01-07")
        history = self.history("alpha")
        self.assertIn("done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", history["ambiguous"])
        self.assertIn("done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", history["ambiguous"])
        first, latest = history["records"]
        self.assertEqual((first["title"], first["links"]), ("First delivery", ["https://example.test/project/pull/1"]))
        self.assertEqual(first["body"], "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)")
        self.assertEqual((latest["title"], latest["body"]), ("Follow-up delivery", "Follow-up scope"))
        self.call("show", "lookalike", good=False)
        self.assertEqual(self.ready(), ["next", "later"], "archived prerequisites did not count as complete")
        for identifier in ("alpha", "beta", "gamma"):
            self.assertIn("already exists", self.call("add", identifier, "Reuse", good=False).stderr)
        self.assertEqual((self.file.read_bytes(), self.archive.read_bytes()), before)
        self.call("add", "delta", "Native completion")
        self.assertEqual(self.archive.read_bytes(), before[1], "an active-only change rewrote the archive")
        self.call("done", "delta", "--keep", "0")
        appended = self.archive.read_text()
        self.assertTrue(appended.startswith(LEGACY_ARCHIVE), "native archival rewrote legacy history")
        self.assertRegex(appended[len(LEGACY_ARCHIVE):], r"\A\n## Archived " + TODAY + r"\n- \[x\] delta - Native completion \(since " + TODAY + r"\) \(done " + TODAY + r"\)\n\Z")
        # A later append by the legacy writer stays readable after native writes.
        with self.archive.open("a") as stream:
            stream.write("\n## Archived 2099-01-01\n- [x] epsilon - Legacy writer row (done 2099-01-01)\n")
        self.assertTrue(self.task("epsilon")["archived"])
        self.assertTrue(self.task("delta")["archived"])
        self.assertEqual(len(self.history("alpha")["records"]), 2)

    def test_reopened_single_record_keeps_identity_and_appends_completion(self):
        self.legacy()
        original = self.history("gamma")["records"]
        self.call("reopen", "gamma")
        reopened = self.task("gamma")
        self.assertEqual((reopened["state"], reopened["archived"], reopened["title"]), ("queued", False, "Unrelated"))
        self.assertEqual(self.archive.read_text(), LEGACY_ARCHIVE)
        self.assertEqual(self.history("gamma")["records"][:-1], original)
        self.assertIn(GAMMA, (self.home / "data/note-archive.md").read_text())
        self.call("add", "gamma", "Reuse", good=False)
        self.call("start", "gamma")
        self.call("done", "gamma", "--keep", "0")
        self.assertEqual([(row["archived"], row["closed"]) for row in self.history("gamma")["records"]], [(True, "2026-01-07"), (True, TODAY)])
        self.assertTrue(self.archive.read_text().startswith(LEGACY_ARCHIVE))
        completed = self.archive.read_bytes()
        self.call("done", "gamma", "--pr", "https://example.test/project/pull/2")
        self.assertEqual(self.task("gamma")["links"], ["https://example.test/project/pull/2"])
        self.assertTrue(self.archive.read_bytes().startswith(completed))
        self.assertEqual(self.history("gamma")["records"][:1], original)
        self.assertEqual(len(self.history("gamma")["records"]), 3)
        self.call("mv", "beta", "--to", str(self.home / "other/data/backlog.md"))
        moved = json.loads(self.call("show", "beta", "--json", path=self.home / "other/data/backlog.md").stdout)["task"]
        self.assertEqual((moved["archived"], moved["closed"]), (True, "2026-01-06"))

    def test_archived_edits_append_idempotent_revisions(self):
        self.legacy()
        commands = [
            ("update", "gamma", "--title", "Revised title", "--repo", "project", "--priority", "1"),
            ("edit", "gamma", "--body", "Retained scope", "--kind", "ship"),
            ("hold", "gamma", "--reason", "Retained question", "--kind", "captain", "--until", "2099-01-01"),
            ("unhold", "gamma"),
            ("block", "gamma", "--by", "beta"),
            ("unblock", "gamma", "--by", "beta"),
            ("close", "gamma", "--pr", "https://example.test/project/pull/2"),
            ("done", "gamma", "--report", "data/gamma/report.md"),
            ("done", "gamma", "--note", "First line\nSecond line"),
            ("rm", "gamma", "--note", "local main"),
        ]
        for command in commands:
            with self.subTest(command=command):
                before = self.snapshot()
                records = self.history("gamma")["records"]
                self.call(*command)
                history = self.history("gamma")
                self.assertIsNone(history["ambiguous"])
                self.assertEqual(history["records"][:-1], records)
                self.assertEqual(history["records"][-1]["closed"], "2026-01-07")
                self.assertIn(", done 2026-01-07)", history["records"][-1]["location"])
                self.assertTrue(self.archive.read_bytes().startswith(before[1]))
                self.assertEqual(self.file.read_bytes(), before[0])
                after = self.snapshot()
                self.call(*command)
                self.assertEqual(self.snapshot(), after)
        gamma = self.task("gamma")
        self.assertEqual((gamma["title"], gamma["repo"], gamma["priority"], gamma["kind"]), ("Revised title", "project", "1", "ship"))
        self.assertEqual(gamma["body"], "Retained scope\n\nFirst line\nSecond line")
        self.assertEqual(gamma["links"], ["https://example.test/project/pull/2", "data/gamma/report.md", "local main"])
        self.assertEqual(gamma["blocked_by"], [])
        self.assertIsNone(gamma["hold_reason"])
        before = self.snapshot()
        for command in (("done", "gamma"), ("rm", "gamma"), ("edit", "gamma")):
            self.call(*command)
            self.assertEqual(self.snapshot(), before)
        self.call("start", "gamma", good=False)
        self.call("update", "gamma", "--title", "Invalid (kind: scout)", good=False)
        self.call("done", "gamma", "--report", "invalid-report.md", good=False)
        self.assertEqual(self.snapshot(), before)

    def test_late_evidence_preserves_legacy_completion_verbs(self):
        self.legacy()
        first, latest = self.digests("alpha")
        self.link("alpha", latest, first)
        for identifier, verb, date in (("alpha", "merged", "2026-01-04"), ("beta", "reported", "2026-01-06")):
            with self.subTest(identifier=identifier):
                before = self.archive.read_bytes()
                records = self.history(identifier)["records"]
                command = ("done", identifier, "--pr", "https://example.test/project/pull/2", "--report", "data/evidence/report.md", "--note", "Additional evidence")
                self.call(*command)
                revised = self.history(identifier)["records"]
                self.assertEqual(revised[:-1], records)
                self.assertIn(f", {verb} {date})", revised[-1]["location"])
                self.assertTrue(self.archive.read_bytes().startswith(before))
                self.assertEqual(self.task(identifier)["closed"], date)
                after = self.snapshot()
                self.call(*command)
                self.assertEqual(self.snapshot(), after)

    def test_late_evidence_after_linked_recompletion_recovers_once(self):
        self.legacy()
        first, latest = self.digests("alpha")
        self.link("alpha", first, latest)
        for crash_after in ("1", "2"):
            with self.subTest(crash_after=crash_after):
                before_reopen = self.archive.read_bytes()
                self.call("reopen", "alpha")
                self.assertEqual(self.archive.read_bytes(), before_reopen)
                self.call("start", "alpha")
                self.call("done", "alpha", "--keep", "0")
                before = self.snapshot()
                records = self.history("alpha")["records"]
                command = ("done", "alpha", "--pr", f"https://example.test/project/pull/{crash_after}", "--report", f"data/alpha/report-{crash_after}.md", "--note", f"Evidence {crash_after}\nRetained detail")
                result = self.call(*command, extra_env={"FM_QUEUE_TEST_CRASH_AFTER_WRITES": crash_after}, good=False)
                self.assertEqual(result.returncode, 91)
                journal = Path(str(self.file) + ".transaction")
                self.assertTrue(journal.exists())
                revised = self.history("alpha")
                self.assertFalse(journal.exists())
                self.assertIsNone(revised["ambiguous"])
                self.assertEqual(revised["records"][:-1], records)
                self.assertIn(f", done {TODAY})", revised["records"][-1]["location"])
                self.assertIn(command[3], self.task("alpha")["links"])
                self.assertIn(command[5], self.task("alpha")["links"])
                self.assertTrue(self.task("alpha")["body"].endswith(command[7]))
                self.assertEqual(self.file.read_bytes(), before[0])
                self.assertTrue(self.archive.read_bytes().startswith(before[1]))
                self.assertTrue((self.home / "data/note-archive.md").read_bytes().startswith(before[2]))
                after = self.snapshot()
                self.call(*command)
                self.assertEqual(self.snapshot(), after)

    def test_single_record_continuation_rm_and_reopen_recover(self):
        self.legacy()
        original = self.history("gamma")["records"]
        result = self.call("reopen", "gamma", extra_env={"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "1"}, good=False)
        self.assertEqual(result.returncode, 91)
        self.assertEqual(self.task("gamma")["state"], "queued")
        self.assertEqual(self.history("gamma")["records"][:-1], original)
        self.assertEqual(self.archive.read_text(), LEGACY_ARCHIVE)
        self.call("start", "gamma")
        self.call("done", "gamma", "--no-prune")
        self.call("rm", "gamma", "--note", "Retention evidence")
        self.assertEqual(self.history("gamma")["records"][:-1], original)
        self.assertTrue(self.task("gamma")["archived"])
        self.assertEqual(self.task("gamma")["body"], "Retention evidence")
        after = self.snapshot()
        self.call("rm", "gamma")
        self.assertEqual(self.snapshot(), after)

    def test_repeated_archived_identity_is_refused_not_guessed(self):
        first = "- [x] dup - Private first title (kind: ship) (done 2026-01-04)\n  Private first scope; digest sha256:00000000synthetic\n"
        cases = {
            "same section": "\n## Archived 2026-01-05\n" + first + "- [x] dup - Private second title (done 2026-01-05)\n",
            "differing kind": "\n## Archived 2026-01-05\n" + first + "\n## Archived 2026-01-09\n- [x] dup - Private second title (kind: task) (done 2026-01-09)\n",
            "prose citation": "\n## Archived 2026-01-05\n" + first + "\n## Archived 2026-01-09\n- [x] dup - Private second title (kind: ship) (done 2026-01-09)\n  Recovery of digest sha256:00000000synthetic\n",
            "ordered dates": "\n## Archived 2026-01-05\n" + first + "\n## Archived 2026-01-09\n- [x] dup - Private first title (kind: ship) (done 2026-01-09)\n",
        }
        for case, archive in cases.items():
            with self.subTest(case=case):
                before = self.legacy("## Queued\n- [ ] other - Unrelated work\n", archive)
                for command in (("show", "dup"), ("reopen", "dup"), ("update", "dup", "--body", "Guess"),
                                ("done", "dup", "--pr", "https://example.test/x/pull/3"), ("rm", "dup"), ("hold", "dup", "--reason", "Guess")):
                    error = self.call(*command, good=False).stderr
                    self.assertIn("ambiguous archived identity dup: archived history is not one linked chain (unlinked records)", error)
                    self.assertIn("done-archive.md:3", error)
                    self.assertNotIn("Private", error)
                self.assertIn("already exists", self.call("add", "dup", "Reuse", good=False).stderr)
                self.call("mv", "dup", "--to", str(self.home / "other/data/backlog.md"), good=False)
                self.assertEqual((self.file.read_bytes(), self.archive.read_bytes()), before)
                self.assertFalse((self.home / "data/note-archive.md").exists())
                self.assertEqual(json.loads(self.call("migrate", "--dry-run").stdout)["ambiguous_histories"], ["dup"])
                self.assertEqual([row["title"] for row in self.history("dup")["records"]], ["Private first title", "Private first title" if case == "ordered dates" else "Private second title"])
                self.call("block", "other", "--by", "dup")
                self.assertEqual(self.ready(), ["other"])
                self.call("done", "other", "--keep", "0")
                self.assertTrue(self.archive.read_text().startswith(archive))
                self.assertTrue(self.task("other")["archived"])

    def snapshot(self):
        return [path.read_bytes() if path.exists() else None for path in (self.file, self.archive, self.home / "data/note-archive.md")]

    def digests(self, identifier):
        return [row["digest"] for row in self.history(identifier)["records"]]

    def link(self, identifier, predecessor, successor, *flags, good=True):
        return self.call("link", identifier, "--predecessor", predecessor, "--successor", successor, *flags, good=good)

    def test_explicit_history_link_resolves_latest_and_reopen_continues_it(self):
        self.legacy()
        first, latest = self.digests("alpha")
        before = self.snapshot()
        preview = json.loads(self.link("alpha", first, latest, "--dry-run").stdout)
        self.assertEqual((preview["recorded"], preview["resolved"]), (False, True))
        self.assertEqual(self.snapshot(), before)
        self.call("show", "alpha", good=False)
        for predecessor, successor in ((first, first), (first, "sha256:" + "0" * 64 + "#1"), (first.split("#")[0], latest), ("prose", latest)):
            for flags in ((), ("--dry-run",)):
                self.link("alpha", predecessor, successor, *flags, good=False)
                self.assertEqual(self.snapshot(), before)
        self.assertIn("no repeated archived records", self.link("beta", first, latest, good=False).stderr)
        self.assertEqual(self.snapshot(), before)
        self.assertTrue(json.loads(self.link("alpha", first, latest).stdout)["resolved"])
        self.assertIn("already recorded", self.link("alpha", first, latest, good=False).stderr)
        self.assertEqual(self.archive.read_text(), LEGACY_ARCHIVE, "linking rewrote archived records")
        alpha = self.task("alpha")
        self.assertEqual((alpha["title"], alpha["archived"], alpha["closed"]), ("Follow-up delivery", True, "2026-01-09"))
        history = self.history("alpha")
        self.assertIsNone(history["ambiguous"])
        self.assertEqual([row["title"] for row in history["records"]], ["First delivery", "Follow-up delivery"])
        self.assertEqual(json.loads(self.call("migrate", "--dry-run").stdout)["ambiguous_histories"], [])
        backup = self.home / "backup"
        self.call("migrate", "--backup-dir", str(backup))
        self.assertEqual([(backup / name).read_bytes() for name in ("0-backlog.md", "1-done-archive.md", "2-note-archive.md")], self.snapshot())
        self.call("reopen", "alpha")
        self.assertEqual(self.archive.read_text(), LEGACY_ARCHIVE, "reopen dropped a linked archived record")
        reopened = self.task("alpha")
        self.assertEqual((reopened["state"], reopened["archived"], reopened["title"]), ("queued", False, "Follow-up delivery"))
        self.assertEqual([row["archived"] for row in self.history("alpha")["records"]], [True, True, False])
        self.call("add", "alpha", "Reuse", good=False)
        self.call("mv", "alpha", "--to", str(self.home / "other/data/backlog.md"), good=False)
        self.call("start", "alpha")
        self.call("done", "alpha", "--keep", "0")
        self.assertTrue(self.archive.read_text().startswith(LEGACY_ARCHIVE))
        history = self.history("alpha")
        self.assertIsNone(history["ambiguous"])
        self.assertEqual([row["closed"] for row in history["records"]], ["2026-01-04", "2026-01-09", TODAY])
        self.assertEqual(self.task("alpha")["closed"], TODAY)
        self.call("reopen", "alpha")
        self.call("done", "alpha", "--no-prune")
        result = self.call("prune", "--keep", "0", extra_env={"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "2"}, good=False)
        self.assertEqual(result.returncode, 91)
        history = self.history("alpha")
        self.assertFalse(Path(str(self.file) + ".transaction").exists())
        self.assertIsNone(history["ambiguous"])
        self.assertEqual(len(history["records"]), 4)
        self.assertTrue(all(row["archived"] for row in history["records"]))

    def test_bad_history_links_stay_ambiguous(self):
        archive = LEGACY_ARCHIVE + "\n## Archived 2026-01-11\n- [x] alpha - Third delivery (done 2026-01-11)\n\n## Archived 2026-01-12\n- [x] twin - Same bytes (done 2026-01-12)\n\n## Archived 2026-01-13\n- [x] twin - Same bytes (done 2026-01-12)\n"
        self.legacy("## Queued\n- [ ] other - Uses alpha blocked-by: alpha\n", archive)
        first, second, third = self.digests("alpha")
        notes = self.home / "data/note-archive.md"

        def entry(identifier, predecessor, successor):
            return f"\n## {identifier} - Completion history link - 2026-01-20T00:00:00+00:00\n\n  predecessor: {predecessor}\n  successor: {successor}\n"
        cases = {
            "dangling history link": entry("alpha", first, "sha256:" + "1" * 64 + "#1") + entry("alpha", second, third),
            "competing history links": entry("alpha", first, second) + entry("alpha", first, third),
            "cyclic history links": entry("alpha", first, second) + entry("alpha", second, first),
            "malformed history link": entry("alpha", first, second) + "\n## alpha - Completion history link - 2026-01-20\n\n  predecessor: guessed\n",
            "unlinked records": entry("alpha", first, second),
        }
        for reason, text in cases.items():
            with self.subTest(reason=reason):
                notes.write_text(text)
                before = self.snapshot()
                for command in (("show", "alpha"), ("reopen", "alpha"), ("update", "alpha", "--title", "Guess")):
                    self.assertIn("(" + reason + ")", self.call(*command, good=False).stderr)
                self.call("add", "alpha", "Reuse", good=False)
                self.assertEqual(self.ready(), ["other"])
                self.assertEqual(self.snapshot(), before)
        notes.write_text(entry("alpha", first, second))
        self.assertIn("competing history links", self.link("alpha", first, third, good=False).stderr)
        self.assertIn("cyclic history links", self.link("alpha", second, first, good=False).stderr)
        self.link("alpha", second, third)
        self.assertEqual(self.task("alpha")["title"], "Third delivery")
        self.assertIn("unlinked records", self.call("show", "twin", good=False).stderr)
        twin_first, twin_second = self.digests("twin")
        self.assertEqual(twin_first.split("#")[0], twin_second.split("#")[0])
        self.link("twin", twin_first, twin_first, good=False)
        notes.write_text(notes.read_text() + entry("twin", twin_first, twin_second.split("#")[0] + "#3"))
        self.assertIn("dangling history link", self.call("show", "twin", good=False).stderr)

    def test_concurrent_history_links_record_once(self):
        self.legacy()
        first, latest = self.digests("alpha")
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            codes = list(pool.map(lambda _: self.link("alpha", first, latest, good=None).returncode, range(4)))
        self.assertEqual(codes.count(0), 1)
        self.assertEqual((self.home / "data/note-archive.md").read_text().count("Completion history link"), 1)
        self.assertEqual(self.task("alpha")["title"], "Follow-up delivery")

    def test_active_record_beside_archived_history_stays_refused(self):
        before = self.legacy("## Queued\n- [ ] beta - Active reuse\n- [ ] other - Unrelated\n")
        notes = self.home / "data/note-archive.md"
        for evidence in (None, "\n## beta - Reopened with identity preserved - 2026-01-08T00:00:00+00:00\n\n" + "- [x] beta - Prerequisite (reported 2026-01-06)\n\n"):
            with self.subTest(evidence=evidence):
                if evidence:
                    notes.write_text(evidence)
                for command in (("show", "beta"), ("add", "unrelated", "Do not guess"), ("migrate", "--dry-run")):
                    error = self.call(*command, good=False).stderr
                    self.assertIn("duplicate active/archive identity: beta; records: done-archive.md:10", error)
                    self.assertIn("backlog.md:2", error)
                self.assertEqual((self.file.read_bytes(), self.archive.read_bytes()), before)

    def test_legacy_history_survives_crash_recovery_and_concurrent_writers(self):
        self.legacy()
        self.call("add", "stable", "Task")
        self.call("done", "stable", "--no-prune")
        result = self.call("prune", "--keep", "0", extra_env={"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "1"}, good=False)
        self.assertEqual(result.returncode, 91)
        self.assertTrue(self.task("stable")["archived"])
        self.assertFalse(Path(str(self.file) + ".transaction").exists())
        self.assertEqual(self.archive.read_text().count("- [x] stable - "), 1)

        def complete(index):
            add = self.call("add", "id-" + str(index), "Concurrent task", good=None)
            done = self.call("done", "id-" + str(index), "--keep", "0", good=None)
            return add.returncode, done.returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=6) as pool:
            self.assertEqual(list(pool.map(complete, range(8))), [(0, 0)] * 8)

        def reuse(_):
            return self.call("add", "alpha", "Reuse", good=None).returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            self.assertNotIn(0, list(pool.map(reuse, range(4))))
        archive = self.archive.read_text()
        self.assertTrue(archive.startswith(LEGACY_ARCHIVE))
        for index in range(8):
            self.assertEqual(archive.count("- [x] id-" + str(index) + " - "), 1)
        self.assertEqual([row["title"] for row in self.history("alpha")["records"]], ["First delivery", "Follow-up delivery"])
        self.assertEqual(json.loads(self.call("migrate", "--dry-run").stdout)["ambiguous_histories"], ["alpha"])

    def test_recoverable_updates_under_same_id(self):
        self.call("add", "scope", "Original title", "--body", "Original scope")
        self.call("edit", "scope", "--body", "Revised scope")
        body = self.home / "body.txt"
        body.write_text("Final scope\nwith detail\n")
        self.call("update", "scope", "--body-file", str(body))
        task = self.task("scope")
        self.assertEqual(task["body"], "Final scope\nwith detail")
        history = (self.home / "data/note-archive.md").read_text()
        self.assertIn("Original scope", history)
        self.assertIn("Revised scope", history)
        self.assertEqual(len(json.loads(self.call("list", "--json").stdout)["tasks"]), 1)

    def test_interrupted_archive_transaction_recovers_once(self):
        self.call("add", "stable", "Task")
        self.call("done", "stable")
        result = self.call("prune", "--keep", "0", extra_env={"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "1"}, good=False)
        self.assertEqual(result.returncode, 91)
        self.assertTrue(Path(str(self.file) + ".transaction").exists())
        self.assertTrue(self.task("stable")["archived"])
        self.assertTrue(self.task("stable")["archived"])
        self.assertFalse(Path(str(self.file) + ".transaction").exists())
        self.call("add", "stable", "Duplicate", good=False)

    def test_multi_id_handoff_and_destination_recovery(self):
        target = self.home / "other/data/backlog.md"
        target.parent.mkdir(parents=True)
        self.call("add", "a", "Blocker")
        self.call("add", "b", "Dependent", "--blocked-by", "a", "--body", "Keep accepted intent")
        self.call("mv", "a", "--to", str(target), good=False)
        result = self.call("mv", "a", "b", "--to", str(target), extra_env={"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "1"}, good=False)
        self.assertEqual(result.returncode, 91)
        moved = json.loads(self.call("show", "b", "--json", path=target).stdout)["task"]
        self.assertEqual(moved["body"], "Keep accepted intent")
        self.assertEqual(moved["blocked_by"], ["a"])
        self.call("show", "a", good=False)
        self.call("show", "b", good=False)

    def test_concurrent_writers_and_duplicate_admission(self):
        def add(index):
            return self.call("add", "id-" + str(index), "Concurrent task").returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=8) as pool:
            self.assertEqual(list(pool.map(add, range(12))), [0] * 12)
        tasks = json.loads(self.call("list", "--json").stdout)["tasks"]
        self.assertEqual(len(tasks), 12)
        def race(_):
            return subprocess.run([str(CLI), "add", "contended", "Once", "--file", str(self.file)], cwd=self.home, env=self.env, capture_output=True).returncode
        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
            codes = list(pool.map(race, range(4)))
        self.assertEqual(codes.count(0), 1)

    def test_compatibility_check_and_backup_never_rewrite(self):
        self.file.write_text("# Existing queue\n\n## In flight\n- **running** - Existing work (repo: project, kind: ship, since 2026-01-01)\n  Accepted intent\n\n## Queued\n- [ ] held - Real question (hold: Choose release) (hold-kind: captain)\n  Answer history is here\n\n## Done\n- [x] old - Delivered - data/old/report.md (reported 2026-01-01)\n")
        before = self.file.read_bytes()
        self.call("migrate", "--dry-run")
        backup = self.home / "backup"
        self.call("migrate", "--backup-dir", str(backup))
        self.assertEqual(self.file.read_bytes(), before)
        self.assertEqual((backup / "0-backlog.md").read_bytes(), before)
        self.assertEqual(self.task("running")["state"], "in_flight")
        self.assertEqual(self.task("running")["kind"], "ship")
        self.assertEqual(self.task("running")["repo"], "project")
        self.assertEqual(self.task("held")["hold_kind"], "captain")
        self.assertIn("data/old/report.md", self.task("old")["links"])
        self.call("done", "old", "--report", "data/old/extra.md")
        self.assertEqual(self.task("old")["closed"], "2026-01-01", "backfill changed a legacy completion date")
        self.call("migrate", "--backup-dir", str(backup), good=False)

    def test_corrupt_records_transactions_and_adapters_fail_closed(self):
        self.file.write_text("## Queued\n- [ ] broken row without identity separator\n")
        before = self.file.read_bytes()
        self.call("add", "a", "Task", good=False)
        self.assertEqual(before, self.file.read_bytes())
        self.file.write_text("## Queued\n- [ ] broken - Task (hold: choose (north)) (hold-kind: captain)\n")
        before = self.file.read_bytes()
        self.call("add", "a", "Do not guess malformed metadata", good=False)
        self.assertEqual(before, self.file.read_bytes())
        self.file.write_text("## Queued\n")
        journal = Path(str(self.file) + ".transaction")
        journal.write_text('{"version":1,"roots":"not a list"}')
        self.call("list", good=False)
        self.assertTrue(journal.exists())
        journal.unlink()
        self.call("list", "--backend", "beads", good=False)

    def test_existing_hold_answer_owner_and_wrapper_need_no_external_cli(self):
        poison = self.home / "poison"
        poison.mkdir()
        marker = self.home / "external-was-called"
        executable = poison / "tasks-axi"
        executable.write_text('#!/bin/sh\ntouch "' + str(marker) + '"\nexit 97\n')
        executable.chmod(0o755)
        env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT), PATH=str(poison) + os.pathsep + self.env["PATH"])

        def owner(*args):
            result = subprocess.run(["bash", str(ROOT / "bin/fm-captain-hold.sh"), *args], env=env, cwd=self.home, capture_output=True, text=True, timeout=30)
            self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
            return result

        result = subprocess.run(["bash", str(ROOT / "bin/fm-queue.sh"), "add", "held-work", "Accepted work", "--body", "Accepted scope"], env=env, cwd=self.home, capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        owner("hold", "held-work", "--reason", "Choose the release")
        self.assertEqual(self.ready(), [])
        owner("open", "held-work")
        decision = self.home / "decision.txt"
        decision.write_text("Use the existing release\n")
        owner("answer", "held-work", "--decision-file", str(decision), "--release")
        self.assertEqual(self.ready(), ["held-work"])
        self.assertEqual(self.task("held-work")["state"], "queued")
        self.assertIn("Use the existing release", self.task("held-work")["body"])
        self.assertFalse(marker.exists(), "runtime invoked external tasks-axi")
        owner("hold", "new-question", "--title", "A real new question", "--reason", "Choose scope")
        self.assertEqual(self.task("new-question")["hold_kind"], "captain")

    def test_existing_dispatch_recovery_reuses_binding_without_completion(self):
        self.call("add", "stable", "Accepted work")
        state = self.home / "state"
        state.mkdir()
        worktree = self.home / "worker-copy"
        worktree.mkdir()
        meta = state / "stable.meta"
        meta.write_text("label=stable\nspawn_gen=1\nbackend=tmux\nwindow=firstmate:fm-stable\nkind=scout\nmode=scout\nharness=codex\nworktree=" + str(worktree) + "\nproject=" + str(worktree) + "\n")
        script = '''set -eu
. "$1/bin/fm-tasks-axi-lib.sh"
. "$1/bin/fm-backlog-transition-lib.sh"
fm_backlog_dispatch_transition "$2/state/stable.meta" "$2/data" stable "$2/state"
fm_backlog_dispatch_transition "$2/state/stable.meta" "$2/data" stable "$2/state"
'''
        result = subprocess.run(["bash", "-c", script, "_", str(ROOT), str(self.home)], env=dict(self.env, FM_HOME=str(self.home)), capture_output=True, text=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertEqual(self.task("stable")["state"], "in_flight")
        self.assertEqual(len(json.loads(self.call("list", "--json").stdout)["tasks"]), 1)
        # The existing current-state owner observes a missing synthetic endpoint.
        # This is a deterministic backend double, not actual agent execution.
        fakebin = self.home / "missing-endpoint-bin"
        fakebin.mkdir()
        endpoint = fakebin / "tmux"
        endpoint.write_text('#!/bin/sh\nprintf "%s\\n" "$*" >> "$FM_QUEUE_TEST_MUX_LOG"\nexit 1\n')
        endpoint.chmod(0o755)
        log = self.home / "endpoint-probes.log"
        env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT), FM_DATA_OVERRIDE=str(self.home / "data"), FM_STATE_OVERRIDE=str(state), FM_CONFIG_OVERRIDE=str(self.home / "config"), FM_BACKEND="tmux", FM_CREW_STATE_NO_FORGE="1", FM_QUEUE_TEST_MUX_LOG=str(log), PATH=str(fakebin) + os.pathsep + self.env["PATH"])
        observation = subprocess.run(["bash", str(ROOT / "bin/fm-crew-state.sh"), "stable"], env=env, cwd=self.home, text=True, capture_output=True, timeout=30)
        self.assertEqual(observation.returncode, 0, observation.stderr)
        self.assertNotIn("state: done", observation.stdout)
        self.assertTrue(log.exists() and log.read_text(), "current-state owner did not probe the endpoint")
        self.assertTrue(meta.exists())
        self.assertEqual(self.task("stable")["state"], "in_flight")

    def test_held_listing_distinguishes_real_questions_from_parked_context(self):
        self.call("add", "idea", "Possible direction", "--idea")
        self.call("add", "outcome", "Retained outcome", "--outcome")
        self.call("add", "question", "Actual question")
        self.call("hold", "question", "--kind", "captain", "--reason", "Choose release")
        result = json.loads(self.call("list", "--state", "held", "--hold-kind", "captain", "--json").stdout)
        self.assertEqual([task["id"] for task in result["tasks"]], ["question"])

    def test_deferral_does_not_answer_a_human_question(self):
        self.call("add", "question", "Actual question")
        self.call("hold", "question", "--kind", "captain", "--reason", "Choose scope", "--until", "2000-01-01")
        self.assertNotIn("question", self.ready())
        self.call("start", "question", good=False)
        self.call("add", "later", "Already authorized later work")
        self.call("hold", "later", "--kind", "future", "--reason", "Start after date", "--until", "2000-01-01")
        self.assertIn("later", self.ready())
        self.call("add", "speculative", "Still an idea", "--idea")
        self.call("hold", "speculative", "--kind", "future", "--reason", "Revisit", "--until", "2000-01-01", good=False)
        self.assertTrue(self.task("speculative")["held"])
        self.assertNotIn("speculative", self.ready())
        self.call("start", "speculative", good=False)

    def test_removal_never_implies_prerequisite_completion(self):
        self.call("add", "a", "Unfinished prerequisite")
        self.call("add", "b", "Dependent", "--blocked-by", "a")
        self.call("rm", "a", good=False)
        self.assertNotIn("b", self.ready())
        self.assertEqual(self.task("a")["state"], "queued")
        self.call("done", "a")
        self.call("rm", "a")
        self.assertTrue(self.task("a")["archived"])
        self.call("add", "a", "Reused identity", good=False)

    def test_hold_reasons_never_supply_structured_metadata(self):
        self.file.write_text("## Queued\n- [ ] question - Legacy question (repo: project, kind: ship) (hold: not urgent, priority: decide P1 or P2) (hold-kind: captain) (hold-until: 2099-01-01)\n")
        self.assertEqual(self.task("question")["hold_reason"], "not urgent, priority: decide P1 or P2")
        self.assertIsNone(self.task("question")["priority"])
        self.assertEqual(self.task("question")["hold_kind"], "captain")
        self.assertEqual(self.ready(), [])
        self.call("add", "work", "Ordinary work")
        self.call("hold", "work", "--reason", "literal, kind: ship")
        self.assertEqual(self.task("work")["kind"], "task", "literal reason changed task kind")
        self.assertEqual(self.task("work")["hold_reason"], "literal, kind: ship")

    def test_archive_cannot_replace_the_active_lock(self):
        (self.home / ".tasks.toml").write_text('backend = "markdown"\n[markdown]\narchive = "data/backlog.md.lock"\n')
        self.call("add", "a", "Task", good=False)
        self.assertFalse(self.file.exists())

    def test_relocated_data_keeps_configured_archive_and_retention(self):
        self.file = self.home / "records/backlog.md"
        self.file.parent.mkdir()
        (self.home / ".tasks.toml").write_text('backend = "markdown"\n[markdown]\npath = "records/backlog.md"\narchive = "history/completed.md"\ndone_keep = 0\n')
        self.call("add", "stable", "Existing accepted work")
        self.call("done", "stable")
        self.assertTrue(self.task("stable")["archived"])
        self.assertTrue((self.home / "history/completed.md").exists())
        self.assertFalse((self.file.parent / "done-archive.md").exists())
        elsewhere = self.home / "elsewhere"
        elsewhere.mkdir()
        result = subprocess.run([str(CLI), "show", "stable", "--json", "--file", str(self.file)], cwd=elsewhere, env=self.env, text=True, capture_output=True)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(json.loads(result.stdout)["task"]["archived"])

    def test_fleet_snapshot_resolves_archived_prerequisite(self):
        self.call("add", "a", "Prerequisite")
        self.call("add", "b", "Dependent", "--blocked-by", "a")
        self.call("done", "a")
        self.call("prune", "--keep", "0")
        self.assertIn("b", self.ready())
        for child in ("state", "config", "projects", "fakebin"):
            (self.home / child).mkdir(exist_ok=True)
        mux = self.home / "fakebin/tmux"
        mux.write_text("#!/bin/sh\nexit 0\n")
        mux.chmod(0o755)
        env = dict(self.env, FM_HOME=str(self.home), FM_ROOT_OVERRIDE=str(ROOT), FM_DATA_OVERRIDE=str(self.home / "data"), FM_STATE_OVERRIDE=str(self.home / "state"), FM_CONFIG_OVERRIDE=str(self.home / "config"), FM_PROJECTS_OVERRIDE=str(self.home / "projects"), FM_BACKEND="tmux", PATH=str(mux.parent) + os.pathsep + self.env["PATH"])
        result = subprocess.run(["bash", str(ROOT / "bin/fm-fleet-snapshot.sh"), "--contribution-input"], env=env, cwd=self.home, text=True, capture_output=True, timeout=30)
        self.assertEqual(result.returncode, 0, result.stderr)
        dependent = next(row for row in json.loads(result.stdout)["backlog"]["records"] if row.get("id") == "b")
        self.assertEqual(dependent["unresolved_blocker_ids"], [], "snapshot disagrees with ready after prerequisite archival")


if __name__ == "__main__":
    unittest.main(verbosity=2)
