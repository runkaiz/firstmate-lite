#!/usr/bin/env python3
"""Firstmate's native Markdown queue; no external queue executable or package.

Usage: fm-queue.py [command] [args] [--file PATH] [--json]
This is the storage interface. Use fm-queue.sh for operational-home addressing.
The existing .tasks.toml Markdown paths/retention and TASKS_AXI_FILE pin are
accepted for compatibility; FM_QUEUE_FILE takes precedence over that old pin.
Only the Markdown backend is supported. Other adapters fail before mutation.

Rows retain the existing Markdown representation. Active/archive/note files
are one authority, protected by a queue lock and a recoverable transaction.
Every body replacement archives its predecessor. Archived IDs stay reserved.
Migration needs no rewrite: `migrate --dry-run` validates existing records;
`migrate --backup-dir DIR` also creates an exclusive byte-for-byte backup.
Neither command activates a home or installs anything. Never run two writers
using different lock protocols against the same queue during activation.
"""

import argparse
import contextlib
import datetime as dt
import hashlib
import fcntl
import json
import os
from pathlib import Path
import re
import shutil
import sys
import tempfile


VERSION = "1.0.0"
SECTIONS = {"In flight": "in_flight", "Queued": "queued", "Done": "done"}
HEADINGS = {v: k for k, v in SECTIONS.items()}
ROW = re.compile(r"^[-*] (?:\[([ xX])\] ([^\s]+)|\*\*([^*]+)\*\*) - (.*)$")
ID = re.compile(r"^[A-Za-z0-9][A-Za-z0-9._-]*$")
META = re.compile(r"\s+\((repo|kind|priority|hold|hold-kind|hold-until):\s*([^)]*)\)|\s+\((since|merged|reported|done)\s+([^)]*)\)")
TODAY = dt.datetime.now(dt.timezone.utc).date().isoformat()


class QueueError(Exception):
    pass


class NotFound(QueueError):
    pass


def require(condition, message):
    if not condition:
        raise QueueError(message)


def canonical(path):
    path = Path(os.path.abspath(path))
    # Resolve parent aliases for locking without following a leaf symlink.
    return path.parent.resolve() / path.name


def regular(path):
    require(not path.is_symlink(), f"refusing symlink: {path}")
    require(not path.exists() or path.is_file(), f"not a regular file: {path}")


def read(path):
    regular(path)
    if not path.exists():
        return None
    with path.open(encoding="utf-8", newline="") as stream:
        return stream.read()


def validate_metadata(metadata):
    for key, value in metadata.items():
        require(isinstance(value, str) and value and not any(char in value for char in "\r\n\t()\0"), "empty or ambiguous queue metadata")
        require(key == "hold" or "," not in value, "ambiguous comma in queue metadata")
    require(metadata.get("priority", "2") in ("0", "1", "2", "3", "4"), "invalid queue priority")
    if "hold-until" in metadata:
        date(metadata["hold-until"])


def atomic(path, text):
    regular(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    fd, name = tempfile.mkstemp(prefix=".fm-queue-", dir=str(path.parent))
    try:
        with os.fdopen(fd, "w", encoding="utf-8", newline="") as stream:
            stream.write(text)
            stream.flush()
            os.fsync(stream.fileno())
        os.replace(name, path)
        directory = os.open(str(path.parent), os.O_RDONLY)
        try:
            os.fsync(directory)
        finally:
            os.close(directory)
    finally:
        if os.path.exists(name):
            os.unlink(name)


def backend_from_config(path, follow_symlinks=False):
    try:
        if path.parent.is_dir() and not os.access(path.parent, os.X_OK):
            raise OSError()
        if follow_symlinks and path.is_symlink():
            require(path.is_file(), "selection must name a regular file")
            content = path.read_text(encoding="utf-8")
        else:
            content = read(path)
    except (OSError, UnicodeError, QueueError) as error:
        raise QueueError(f"tasks-axi backend configuration cannot be read at {path}") from error
    selected = None
    for line in (content or "").splitlines():
        line = line.strip()
        if not line or line.startswith("#"):
            continue
        if re.fullmatch(r"\[[^\[\]]+\]\s*(?:#.*)?", line):
            break
        match = re.fullmatch(r"([A-Za-z_][A-Za-z0-9_-]*)\s*=\s*(.+)", line)
        require(match is not None, f"unsupported or malformed backend selection in {path}")
        if match[1] == "backend":
            value = re.fullmatch(r'(\"[^\"\\]*\"|\x27[^\x27]*\x27)\s*(?:#.*)?', match[2])
            require(value is not None and selected is None, f"unsupported or malformed backend selection in {path}")
            selected = value[1][1:-1]
    return selected


def resolve_backend(cfg, override=None):
    selected, source = override, "--backend"
    if selected is None:
        for variable in ("FM_QUEUE_BACKEND", "TASKS_AXI_BACKEND"):
            if variable in os.environ:
                selected, source = os.environ[variable], variable
                break
    if selected is None:
        source = cfg
        selected = backend_from_config(source)
    if selected is None and os.environ.get("HOME"):
        source = Path(os.environ["HOME"]) / ".tasks-axi/config.toml"
        selected = backend_from_config(source, follow_symlinks=True)
    if selected is None:
        return "markdown"
    require(selected == "markdown", f"native queue supports Markdown only; backend selected by {source} requires an explicit compatible export before activation")
    return selected


def config(file=None, backend=None):
    # Preserve the existing file layout, not the external CLI's global state.
    settings = {"path": "data/backlog.md", "archive": None, "done_keep": 10}
    section = ""
    cwd = Path.cwd().resolve()
    cfg = cwd / ".tasks.toml"
    pin = file or os.environ.get("FM_QUEUE_FILE") or os.environ.get("TASKS_AXI_FILE")
    if pin:
        candidate = canonical(pin)
        roots = [candidate.parent, candidate.parent.parent]
        found = [root / ".tasks.toml" for root in roots if (root / ".tasks.toml").exists() or (root / ".tasks.toml").is_symlink()]
        if cwd in roots and (cfg.exists() or cfg.is_symlink()):
            pass  # Lifecycle/home wrapper explicitly selected this root.
        elif found:
            require(len(found) == 1, "ambiguous queue configuration roots; run from the owning root")
            cfg = found[0]
        else:
            cfg = candidate.parent / ".tasks.toml"
    resolve_backend(cfg, backend)
    content = read(cfg)
    if content is not None:
        # This intentionally supports the existing bounded Markdown schema,
        # rather than requiring a new TOML package at runtime.
        for line in content.splitlines():
            line = line.strip()
            if not line or line.startswith("#"):
                continue
            if line.startswith("[") and line.endswith("]"):
                section = line[1:-1]
                continue
            match = re.fullmatch(r'(backend|path|archive|done_keep)\s*=\s*("[^"\n]*"|\x27[^\x27\n]*\x27|\d+)\s*(?:#.*)?', line)
            if match and (section == "markdown" or (section == "" and match[1] == "backend")):
                key, value = match.groups()
                if key != "backend":
                    settings[key] = int(value) if key == "done_keep" else value[1:-1]
            elif section in ("", "markdown"):
                raise QueueError(f"unsupported or malformed queue configuration in {cfg}: {line}")
    require(settings["path"] and settings["archive"] != "", "queue and archive paths must not be empty")
    path = canonical(pin or cfg.parent / settings["path"])
    archive = Path(settings["archive"]) if settings["archive"] else path.parent / "done-archive.md"
    if not archive.is_absolute():
        archive = cfg.parent / archive
    archive = canonical(archive)
    require(path != canonical(cfg) and archive != canonical(cfg), "queue data must not replace its configuration")
    return path, archive, settings["done_keep"]


class Task:
    def __init__(self, identifier, title, state="queued", raw="", body="", metadata=None, deps=None, links=None):
        require(ID.fullmatch(identifier) is not None, f"invalid task ID: {identifier!r}")
        self.id, self.title, self.state = identifier, title, state
        self.raw, self.body = raw, body
        self.meta = metadata or {}
        if "kind" not in self.meta:
            prefix = re.match(r"^(SCOUT|SHIP)(?![A-Za-z0-9_])", title)
            if prefix:
                self.meta["kind"] = prefix[1].lower()
        self.deps, self.links = deps or [], links or []
        self.dirty = not raw
        self.archived = False
        self.block_reason = ""

    @classmethod
    def parse(cls, lines, state):
        match = ROW.fullmatch(lines[0].rstrip("\r\n"))
        require(match is not None, "malformed task row")
        checked, identifier, bold, rest = match.groups()
        require(state in HEADINGS, f"task {identifier or bold} outside a recognized section")
        require(checked is None or (checked.lower() == "x") == (state == "done"), f"checkbox/section conflict for {identifier}")
        metadata = {}

        def remove(m):
            content = m[0].strip()[1:-1]
            # A hold owns its entire parenthesized value. Metadata-looking
            # prose in a reason never grants kind, priority or dependencies.
            if m[1] == "hold":
                require("hold" not in metadata, f"duplicate hold metadata for {identifier or bold}")
                metadata["hold"] = m[2].strip()
                return ""
            components = re.split(r",\s*(?=(?:repo|kind|priority|hold|hold-kind|hold-until):|(?:since|merged|reported|done)\s)", content)
            for component in components:
                item = re.fullmatch(r"(repo|kind|priority|hold|hold-kind|hold-until):\s*(.*)|(since|merged|reported|done)\s+(.*)", component)
                require(item is not None, f"malformed metadata for {identifier or bold}")
                key, value = (item[1], item[2]) if item[1] else (item[3], item[4])
                require(key != "hold", "a hold reason requires its own metadata block")
                require(key not in metadata, f"duplicate {key} metadata for {identifier or bold}")
                metadata[key] = value.strip()
            return ""

        rest = META.sub(remove, rest)
        deps = re.findall(r"\bblocked-by:\s*([^\s,)]+)", rest)
        reason = re.search(r"\s+blocked-by:\s*[^\s,)]+\s+-\s+(.*)$", rest)
        rest = re.sub(r"\s+blocked-by:.*$", "", rest)
        links = []
        while " - " in rest:
            prefix, link = rest.rsplit(" - ", 1)
            if not link.startswith(("https://", "http://", "<https://", "<http://", "data/", "/")) and link != "local main":
                break
            links.insert(0, link.strip("<>"))
            rest = prefix
        body_lines = lines[1:]
        while body_lines and body_lines[-1] in ("\n", "\r\n"):
            body_lines.pop()
        body = "\n".join(line[2:].rstrip("\r\n") if line.startswith("  ") else line.rstrip("\r\n") for line in body_lines)
        task = cls(identifier or bold, rest.strip(), state, "".join(lines), body, metadata, list(dict.fromkeys(deps)), links)
        require(bool(task.title), f"empty title for {task.id}")
        task.block_reason = reason[1] if reason else ""
        require(not (metadata.get("hold-kind") or metadata.get("hold-until")) or bool(metadata.get("hold")), f"hold metadata without reason for {task.id}")
        validate_metadata(task.meta)
        return task

    def render(self):
        if not self.dirty:
            return self.raw
        title = self.title
        for link in self.links:
            title += " - " + link
        for key in ("repo", "kind", "since", "priority", "merged", "reported", "done", "hold", "hold-kind", "hold-until"):
            if key in self.meta:
                delimiter = " " if key in ("since", "merged", "reported", "done") else ": "
                title += f" ({key}{delimiter}{self.meta[key]})"
        for dependency in self.deps:
            title += f" blocked-by: {dependency}"
        if self.deps and self.block_reason:
            title += " - " + self.block_reason
        result = f"- [{'x' if self.state == 'done' else ' '}] {self.id} - {title}\n"
        if self.body:
            result += "".join("  " + line + "\n" for line in self.body.split("\n"))
        return result

    def held(self):
        if self.state == "done":
            return False
        if self.meta.get("kind") in ("idea", "outcome"):
            return True
        return bool(self.meta.get("hold")) and (self.meta.get("hold-kind") == "captain" or not self.meta.get("hold-until") or self.meta["hold-until"] > TODAY)

    def blocked(self, all_tasks):
        return [dep for dep in self.deps if dep not in all_tasks or all_tasks[dep].state != "done"]

    def completion(self):
        for key in ("merged", "reported", "done"):
            if key in self.meta:
                return {"verb": key, "date": self.meta[key]}
        return {"verb": None, "date": None}

    def snapshot_metadata(self):
        result = {key: self.meta.get(key) for key in ("repo", "kind", "priority", "since", "merged", "reported", "done")}
        result.update({"state": self.state, "hold_reason": self.meta.get("hold"), "hold_kind": self.meta.get("hold-kind"), "hold_until": self.meta.get("hold-until"), "blocked_by_ids": self.deps, "blocked_by": self.deps[-1] if self.deps else None, "blocked_reason": self.block_reason or None, "completion": self.completion()})
        return result

    def data(self, all_tasks):
        return {"id": self.id, "title": self.title, "state": self.state, "kind": self.meta.get("kind", "task"),
                "repo": self.meta.get("repo"), "priority": self.meta.get("priority"), "held": self.held(),
                "hold_reason": self.meta.get("hold"), "hold_kind": self.meta.get("hold-kind"), "hold_until": self.meta.get("hold-until"),
                "blocked": bool(self.blocked(all_tasks)), "blocked_by": self.deps, "deps": self.deps,
                "created": self.meta.get("since"), "closed": self.completion()["date"],
                "links": self.links, "body": self.body, "archived": self.archived}


class Document:
    def __init__(self, text):
        self.parts = []
        require(not any(ord(char) < 32 and char not in "\t\r\n" for char in text or ""), "queue contains a control byte")
        section = None
        lines = re.split(r"(?<=\n)", text or "## In flight\n\n## Queued\n\n## Done\n")
        if lines[-1] == "":
            lines.pop()
        index = 0
        seen_sections = set()
        while index < len(lines):
            line = lines[index]
            heading = re.fullmatch(r"##\s+([^\r\n]+)\s*\n?", line)
            if heading:
                section = SECTIONS.get(heading[1].strip())
                if section:
                    require(section not in seen_sections, f"duplicate section: {section}")
                    seen_sections.add(section)
            if ROW.fullmatch(line.rstrip("\r\n")):
                end = index + 1
                while end < len(lines) and (lines[end].startswith(("  ", "\t")) or not lines[end].strip()):
                    end += 1
                self.parts.append(Task.parse(lines[index:end], section))
                index = end
                continue
            require(not re.match(r"^[-*]\s+\[[ xX]\]", line), f"malformed task row: {line.rstrip()}")
            self.parts.append(line)
            index += 1

    def tasks(self):
        return [part for part in self.parts if isinstance(part, Task)]

    def insert(self, task):
        start = None
        end = len(self.parts)
        for index, part in enumerate(self.parts):
            if not isinstance(part, str) or not part.startswith("## "):
                continue
            if start is not None:
                end = index
                break
            if part.strip() == "## " + HEADINGS[task.state]:
                start = index + 1
        if start is None:
            self.parts.extend(["\n", "## " + HEADINGS[task.state] + "\n"])
            start = end = len(self.parts)
        self.parts.insert(start if task.state == "done" else end, task)

    def render(self):
        return "".join(part.render() if isinstance(part, Task) else part for part in self.parts)


class Store:
    def __init__(self, path=None, backend=None):
        self.path, self.archive, self.keep = config(path, backend)
        self.notes = self.path.parent / "note-archive.md"
        self.journal = Path(str(self.path) + ".transaction")
        self.lock = Path(str(self.path) + ".lock")
        require(len({self.path, self.archive, self.notes, self.journal, self.lock}) == 5, "queue files and lock must be distinct")

    def load(self):
        self.active = Document(read(self.path))
        self.past = Document(read(self.archive) or "## Done\n")
        self.note_text = read(self.notes) or ""
        self.original = {path: read(path) for path in (self.path, self.archive, self.notes)}
        self.all = {}
        for archived, document in ((False, self.active), (True, self.past)):
            for task in document.tasks():
                require(task.id not in self.all, f"duplicate active/archive identity: {task.id}")
                require(not archived or task.state == "done", f"non-complete archived record: {task.id}")
                task.archived = archived
                self.all[task.id] = task

    def find(self, identifier):
        if identifier not in self.all:
            raise NotFound(f'Task "{identifier}" not found in this backlog or archive')
        return self.all[identifier]

    def remove(self, task):
        (self.past if task.archived else self.active).parts.remove(task)

    def history(self, task, reason="Body replaced"):
        self.note_text += f"\n## {task.id} - {reason} - {dt.datetime.now(dt.timezone.utc).isoformat()}\n\n" + task.render() + "\n"

    def prune(self, keep):
        done = [task for task in self.active.tasks() if task.state == "done"]
        for task in done[keep:]:
            self.active.parts.remove(task)
            task.archived = True
            self.past.insert(task)

    def changes(self):
        result = {self.path: self.active.render(), self.archive: self.past.render(), self.notes: self.note_text}
        if self.original[self.archive] is None and not self.past.tasks():
            result.pop(self.archive)
        return {path: text for path, text in result.items() if text != (self.original[path] or "")}


@contextlib.contextmanager
def locks(paths):
    streams = []
    try:
        for path in sorted(set(paths), key=str):
            path.parent.mkdir(parents=True, exist_ok=True)
            lock = Path(str(path) + ".lock")
            regular(lock)
            stream = open(lock, "a+b")
            streams.append(stream)
            fcntl.flock(stream, fcntl.LOCK_EX)
        yield
    finally:
        for stream in reversed(streams):
            stream.close()


def journal_read(path):
    raw = read(path)
    if raw is None:
        return None
    try:
        data = json.loads(raw)
        require(data["version"] == 1 and isinstance(data["roots"], list) and 1 <= len(data["roots"]) <= 2, "invalid transaction roots")
        require(all(isinstance(root, str) and Path(root).is_absolute() for root in data["roots"]), "invalid transaction root path")
        require(len(set(data["roots"])) == len(data["roots"]) and all(str(canonical(root)) == root for root in data["roots"]), "ambiguous transaction roots")
        require(isinstance(data["files"], list) and 1 <= len(data["files"]) <= 6, "invalid transaction files")
        return data
    except (ValueError, KeyError, TypeError) as error:
        raise QueueError(f"corrupt transaction {path}: {error}") from error


def recover(data, stores):
    require(set(data["roots"]) == {str(store.path) for store in stores}, "transaction ownership changed; retry with its full locked roots")
    allowed = {str(path) for store in stores for path in (store.path, store.archive, store.notes)}
    seen = set()
    for store in stores:
        if store.journal.exists():
            require(journal_read(store.journal) == data, "conflicting participant transaction")
    for entry in data["files"]:
        require(isinstance(entry, dict) and entry.get("path") in allowed and entry["path"] not in seen, "unsafe or duplicate transaction file")
        require(isinstance(entry.get("after"), str) and (entry.get("before") is None or isinstance(entry.get("before"), str)), "invalid transaction payload")
        seen.add(entry["path"])
        require(read(Path(entry["path"])) in (entry["before"], entry["after"]), f"transaction conflicts with changed file: {entry['path']}")
    # Validate every participant before writing any byte.
    for entry in data["files"]:
        if read(Path(entry["path"])) != entry["after"]:
            atomic(Path(entry["path"]), entry["after"])
    for store in stores:
        if store.journal.exists():
            store.journal.unlink()


def commit(stores):
    files = []
    for store in stores:
        # An input must not serialize into metadata or a second task identity.
        # Validate before publishing a transaction, including unchanged siblings.
        identities = set()
        for document in (store.active, store.past):
            for task in document.tasks():
                require(task.id not in identities, f"duplicate queue identity: {task.id}")
                identities.add(task.id)
                if task.dirty:
                    require(not META.search(" " + task.title) and "blocked-by:" not in task.title, "title contains reserved queue metadata")
                    validate_metadata(task.meta)
            parsed = {task.id: task for task in Document(document.render()).tasks()}
            for task in document.tasks():
                if task.dirty:
                    require(parsed[task.id].meta == task.meta, "metadata does not round-trip; use the encoded hold owner for literal reasons")
                    require(all(getattr(parsed[task.id], field) == getattr(task, field) for field in ("title", "body", "links", "deps", "state")), "task content does not round-trip; ambiguous queue representation")
        for path, text in store.changes().items():
            files.append({"path": str(path), "before": store.original[path], "after": text})
    if not files:
        return
    data = {"version": 1, "roots": [str(store.path) for store in stores], "files": files}
    for store in stores:
        require(not store.journal.exists(), "unrecovered queue transaction")
        atomic(store.journal, json.dumps(data, ensure_ascii=False))
    for index, entry in enumerate(files, 1):
        atomic(Path(entry["path"]), entry["after"])
        # Deterministic crash-window regression; ordinary execution never sets it.
        if os.environ.get("FM_QUEUE_TEST_CRASH_AFTER_WRITES") == str(index):
            os._exit(91)
    for store in stores:
        store.journal.unlink()


def date(value):
    try:
        require(dt.date.fromisoformat(value).isoformat() == value, f"invalid date: {value}")
    except ValueError as error:
        raise QueueError(f"invalid date: {value}") from error
    return value


def scalar(value):
    if value is None or value == "":
        return '"-"'
    if isinstance(value, bool):
        return "yes" if value else "no"
    if isinstance(value, list):
        return ",".join(value) if value else "none"
    text = str(value)
    return json.dumps(text, ensure_ascii=False) if any(char in text for char in '\n\r\t"\\') else text


def table(name, tasks, fields, all_tasks):
    print(f"{name}[{len(tasks)}]{{{','.join(fields)}}}:")
    for task in tasks:
        values = task.data(all_tasks)
        cells = []
        for key in fields:
            value = values.get(key)
            if isinstance(value, list):
                value = ",".join(value) if value else "none"
            text = json.dumps(value, ensure_ascii=False) if (key == "hold_reason" and isinstance(value, str)) or (key == "body" and value == "") else scalar(value)
            # TOON uses JSON string escapes, not RFC CSV doubled quotes.
            if not text.startswith('"') and ("," in text or text != text.strip()):
                text = json.dumps(text, ensure_ascii=False)
            cells.append(text)
        print("  " + ",".join(cells))


def output(task, store, options, message=None):
    data = task.data(store.all)
    if options.json:
        print(json.dumps({"ok": True, "task": data}, ensure_ascii=False))
        return
    if message:
        print("ok: " + message)
    print("task:")
    for key, value in data.items():
        text = json.dumps(value, ensure_ascii=False) if (key == "hold_reason" and isinstance(value, str)) or (key == "body" and value == "") else scalar(value)
        print(f"  {key}: {text}")


def parser():
    p = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.epilog = '''Commands (aliases share the same authority):
  add/create <id> "<title>" [--body-file PATH] [--idea | --outcome]
  authorize <id> --body-file PATH [--kind ship|scout|task]
  show/view <id> [--full]    list [--state STATE] [--fields a,b]
  ready [--repo NAME] [--include-held]
  update/edit <id> [--body-file PATH] [--title TEXT] [--priority 0-4]
  hold <id> --reason TEXT [--kind captain|external|load|parked|future]
       [--until YYYY-MM-DD]   unhold <id>
  block/unblock <id> --by <other-id>
  start <id>    done/close <id> [--pr URL] [--report PATH] [--note TEXT]
       [--keep N | --no-prune]    reopen <id>
  prune [--keep N]    rm <completed-id>
  mv <id> [<id>...] --to <queue-file-or-directory>
  snapshot    check    migrate --dry-run    migrate --backup-dir <new-directory>

Dates are UTC. Captain holds require an answer/release even after their date.
Storage --start is accepted for compatibility imports; fm-queue.sh refuses
add/create --start because fm-spawn owns the worker binding.
--json returns structured records; ordinary output is the existing TOON API.
'''
    p.add_argument("command", nargs="?", default="list")
    p.add_argument("items", nargs="*")
    for flag in ("file", "backend", "kind", "hold-kind", "repo", "body", "body-file", "title", "pr", "report", "note", "to", "reason", "until", "fields", "backup-dir"):
        p.add_argument("--" + flag)
    p.add_argument("--priority", choices=list("01234"))
    p.add_argument("--state", choices=("queued", "in_flight", "done", "held"))
    p.add_argument("--blocked-by", action="append", default=[])
    p.add_argument("--by", action="append", default=[])
    p.add_argument("--limit", type=int)
    p.add_argument("--keep", type=int)
    for flag in ("json", "full", "archive-body", "start", "blocked", "include-held", "idea", "outcome", "dry-run", "no-prune"):
        p.add_argument("--" + flag, action="store_true")
    p.add_argument("--version", "-V", action="version", version=VERSION)
    return p


def execute(options, stores):
    store = stores[0]
    verb = {"create": "add", "view": "show", "edit": "update", "close": "done"}.get(options.command, options.command)
    items = options.items
    if options.body_file:
        require(options.body is None, "choose --body or --body-file")
        options.body = Path(options.body_file).read_text(encoding="utf-8").rstrip("\n")
    if verb == "snapshot":
        require(not items, "snapshot takes no task IDs")
        # One locked observation for existing projections, including archive
        # prerequisite facts without publishing every historical task body.
        print(json.dumps({"text": store.active.render(), "closed_ids": [task.id for task in store.all.values() if task.state == "done"], "metadata": {task.id: task.snapshot_metadata() for task in store.active.tasks()}}, ensure_ascii=False))
        return
    if verb in ("check", "migrate"):
        require(not items, "unexpected check arguments")
        require(not (options.dry_run and options.backup_dir), "choose --dry-run or --backup-dir")
        if options.backup_dir:
            backup = Path(options.backup_dir)
            require(not backup.exists(), "backup directory already exists")
            backup.mkdir(parents=True, mode=0o700)
            manifest = []
            for index, path in enumerate((store.path, store.archive, store.notes)):
                regular(path)
                if path.exists():
                    target = backup / f"{index}-{path.name}"
                    shutil.copy2(path, target)
                    manifest.append({"source": str(path), "backup": target.name, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()})
            atomic(backup / "manifest.json", json.dumps(manifest, indent=2))
        print(json.dumps({"ok": True, "records": len(store.all), "format": "compatible-markdown", "rewrite_required": False, "activated": False}))
        return
    if verb in ("list", "ready"):
        tasks = store.active.tasks()
        if options.repo:
            tasks = [task for task in tasks if task.meta.get("repo") == options.repo]
        if options.kind:
            tasks = [task for task in tasks if task.meta.get("kind", "task") == options.kind]
        if options.hold_kind:
            tasks = [task for task in tasks if task.meta.get("hold-kind") == options.hold_kind]
        if options.state:
            tasks = [task for task in tasks if task.held()] if options.state == "held" else [task for task in tasks if task.state == options.state]
        if options.blocked:
            tasks = [task for task in tasks if task.blocked(store.all)]
        held = [task for task in tasks if task.held()]
        if verb == "ready":
            tasks = [task for task in tasks if task.state == "queued" and not task.held() and not task.blocked(store.all) and task.meta.get("kind") not in ("idea", "outcome")]
            tasks.sort(key=lambda task: int(task.meta.get("priority", "2")))
        if options.limit is not None:
            require(options.limit >= 0, "limit must be nonnegative")
            tasks = tasks[:options.limit]
        if options.json:
            print(json.dumps({"tasks": [task.data(store.all) for task in tasks]}, ensure_ascii=False))
        else:
            fields = list(dict.fromkeys(["id", "title", "state", "kind", "repo"] + (options.fields.split(",") if options.fields else [])))
            table("ready" if verb == "ready" else "tasks", tasks, fields, store.all)
            if verb == "ready" and options.include_held:
                table("held", held, fields, store.all)
        return
    if verb == "prune":
        require(options.state in (None, "done"), "only completed work may be archived")
        keep = store.keep if options.keep is None else options.keep
        require(keep >= 0, "keep must be nonnegative")
        store.prune(keep)
        commit(stores)
        print("ok: archived completed records; identities retained")
        return
    if verb == "mv":
        require(items and options.to, "mv <id> [<id>...] --to <path-or-dir>")
        destination = stores[1]
        identifiers = list(dict.fromkeys(items))
        moving = [store.find(identifier) for identifier in identifiers]
        require(not any(identifier in destination.all for identifier in identifiers), "destination has an active or archived identity conflict")
        for task in moving:
            require(all(dep in identifiers or dep in destination.all for dep in task.deps), f"move would strand dependency of {task.id}")
        for task in store.active.tasks():
            require(task.id in identifiers or task.state == "done" or not any(dep in identifiers for dep in task.deps), f"move would strand dependent {task.id}")
        for task in moving:
            store.remove(task)
            (destination.past if task.archived else destination.active).insert(task)
            destination.all[task.id] = task
            del store.all[task.id]
        commit(stores)
        print(json.dumps({"ok": True, "moved": identifiers}))
        return
    require(verb in ("add", "show", "start", "done", "reopen", "update", "hold", "unhold", "block", "unblock", "rm", "authorize"), f"unsupported native queue command: {verb}")
    require(items, f"{verb} requires a task ID")
    if verb == "add":
        require(len(items) == 2, 'add <id> "<title>"')
        identifier, title = items
        require(identifier not in store.all, f"identity already exists in active queue or archive: {identifier}")
        idea = options.idea or options.kind == "idea"
        outcome = options.outcome or options.kind == "outcome"
        require(not (idea and outcome), "choose idea or outcome")
        require(not (options.start and (idea or outcome)), "retained context cannot start")
        require("\n" not in title and "\r" not in title and title.strip(), "title must be one nonempty line")
        task = Task(identifier, title, "in_flight" if options.start else "queued", body=options.body or "", metadata={"since": TODAY})
        for key in ("kind", "repo", "priority"):
            if getattr(options, key) is not None:
                task.meta[key] = getattr(options, key)
        if idea or outcome:
            task.meta.update({"kind": "idea" if idea else "outcome", "hold-kind": "parked", "hold": "idea only; not authorized" if idea else "outcome context; not executable"})
        task.deps = list(dict.fromkeys(options.blocked_by))
        require(all(dep in store.all for dep in task.deps), "dependency does not exist")
        store.all[identifier] = task
        store.active.insert(task)
    else:
        require(len(items) == 1, f"{verb} requires exactly one task ID")
        task = store.find(items[0])
        if verb == "show":
            output(task, store, options)
            return
        if verb in ("update", "authorize"):
            if verb == "update" and options.kind is not None and options.kind != task.meta.get("kind"):
                require(task.meta.get("kind") not in ("idea", "outcome") and options.kind not in ("idea", "outcome"), "retained context kind cannot be changed by update; use authorize for a parked idea")
            if verb == "authorize":
                require(task.meta.get("kind") == "idea" and task.meta.get("hold-kind") == "parked", "authorize requires a parked idea")
                require(options.kind not in ("idea", "outcome"), "authorization must select executable work, not retained context")
                require(options.body and options.body.strip(), "record the actual authorization and scope with --body or --body-file")
            changed = verb == "authorize" or (options.body is not None and options.body != task.body) or (options.title is not None and options.title != task.title)
            changed = changed or any(getattr(options, key) is not None and getattr(options, key) != task.meta.get(key) for key in ("repo", "kind", "priority"))
            if changed:
                store.history(task)
            if options.body is not None:
                task.body = options.body
            for key in ("repo", "kind", "priority"):
                if getattr(options, key) is not None:
                    task.meta[key] = getattr(options, key)
            if options.title is not None:
                require(options.title.strip() and "\n" not in options.title and "\r" not in options.title, "invalid title")
                task.title = options.title
            if verb == "authorize":
                task.meta["kind"] = options.kind or "task"
                for key in ("hold", "hold-kind", "hold-until"):
                    task.meta.pop(key, None)
        elif verb in ("start", "done", "reopen", "rm"):
            require(verb != "rm" or task.state == "done", "unfinished work cannot be removed as if completed; retain it with a parked hold")
            was_done = task.state == "done"
            if verb == "start" and task.state != "in_flight":
                require(task.state != "done" and not task.held() and not task.blocked(store.all) and task.meta.get("kind") not in ("idea", "outcome"), "task is not eligible for dispatch")
            if verb == "reopen" and task.state == "done":
                store.history(task, "Reopened with identity preserved")
            elif not was_done and any(key in task.meta for key in ("done", "merged", "reported")):
                store.history(task, "Prior completion context retained")
            store.remove(task)
            task.state = "in_flight" if verb == "start" else "queued" if verb == "reopen" else "done"
            if task.state == "done" and not was_done:
                for key in ("merged", "reported"):
                    task.meta.pop(key, None)
                task.meta["done"] = TODAY
            elif task.state != "done":
                task.meta.pop("done", None)
                task.meta.pop("merged", None)
                task.meta.pop("reported", None)
            task.archived = verb == "rm" or (task.archived and verb == "done")
            (store.past if task.archived else store.active).insert(task)
        elif verb == "hold":
            require(options.reason and options.reason.strip() and not any(c in options.reason for c in "\n\r()"), "hold requires a single-line --reason without parentheses")
            require(options.kind in (None, "captain", "external", "load", "parked", "future"), "invalid hold kind")
            require(task.meta.get("kind") not in ("idea", "outcome") or options.kind == "parked", "retained context must keep a parked hold; use authorize for a parked idea")
            task.meta["hold"] = options.reason
            if options.kind:
                task.meta["hold-kind"] = options.kind
            else:
                task.meta.pop("hold-kind", None)
            if options.until:
                task.meta["hold-until"] = date(options.until)
            else:
                task.meta.pop("hold-until", None)
        elif verb == "unhold":
            require(task.meta.get("kind") not in ("idea", "outcome"), "retained context requires explicit authorization, not unhold")
            for key in ("hold", "hold-kind", "hold-until"):
                task.meta.pop(key, None)
        elif verb in ("block", "unblock"):
            require(options.by, "dependency operation requires --by")
            for dep in options.by:
                require(dep != task.id and dep in store.all, "dependency must name another existing task")
                if verb == "block" and dep not in task.deps:
                    task.deps.append(dep)
                elif verb == "unblock" and dep in task.deps:
                    task.deps.remove(dep)
        task.dirty = True
    for link in (options.pr, options.report):
        if link and link not in task.links:
            require("\n" not in link and "\r" not in link, "artifact link must be one line")
            task.links.append(link)
            task.dirty = True
    if verb == "done" and (options.pr or options.report):
        completed = task.completion()["date"]
        if completed:
            for key in ("done", "merged", "reported"):
                task.meta.pop(key, None)
            task.meta["reported" if options.report else "merged"] = completed
            task.dirty = True
    if options.note:
        if options.note == "local main":
            if options.note not in task.links:
                task.links.append(options.note)
        elif options.note not in task.body.split("\n"):
            store.history(task, "Completion note added")
            task.body = task.body + "\n\n" + options.note if task.body else options.note
        task.dirty = True
    if verb == "done" and not options.no_prune:
        keep = store.keep if options.keep is None else options.keep
        require(keep >= 0, "keep must be nonnegative")
        store.prune(keep)
    commit(stores)
    output(task, store, options, f"{verb} {task.id}")


def main():
    require(sys.version_info >= (3, 9), "native queue requires Python 3.9 or newer")
    options = parser().parse_intermixed_args()
    source = Store(options.file, options.backend)
    paths = [source.path]
    if options.command == "mv" and options.to:
        target = canonical(options.to)
        if target.is_dir():
            target = target / "data/backlog.md" if (target / "data").is_dir() else target / "backlog.md"
        require(target != source.path, "source and destination are the same queue")
        paths.append(target)
    pending = journal_read(source.journal)
    if pending:
        paths = list(dict.fromkeys(paths + [Path(root) for root in pending["roots"]]))
    require(len(paths) <= 2, "finish pending handoff recovery before another transfer")
    stores = [source] + [Store(str(path)) for path in paths[1:]]
    owned = [path for store in stores for path in (store.path, store.archive, store.notes)]
    require(len(set(owned)) == len(owned), "queue participants share a storage file")
    with locks(paths):
        for store in stores:
            data = journal_read(store.journal)
            if data:
                require(not options.dry_run and options.command != "migrate", "pending transaction requires recovery before compatibility check")
                recover(data, stores)
        for store in stores:
            store.load()
        execute(options, stores)


if __name__ == "__main__":
    try:
        main()
    except NotFound as error:
        print("code: NOT_FOUND")
        print("error: " + str(error))
        sys.exit(1)
    except (QueueError, OSError, UnicodeError, ValueError, KeyError, TypeError) as error:
        print("error: " + str(error), file=sys.stderr)
        sys.exit(1)
