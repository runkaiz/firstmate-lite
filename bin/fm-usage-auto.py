#!/usr/bin/env python3
"""Private automatic discovery for fm-usage-ledger.py; no scheduler or model calls.

Usage: fm-usage-auto.py refresh|status --home DIR [--force]
       [--remember TASK | --retire TASK]
       [--store DIR] [--max-bytes N] [--max-candidates N]

refresh is enabled by default; config/usage-ledger containing exactly off disables
it. Lifecycle callers must pass their resolved home/state/data/config explicitly
through FM_HOME and FM_*_OVERRIDE, or --home. A worker checkout is never a home
fallback. --store isolates verification from the stable data/usage-ledger store.
The private catalog contains only source locators and allowlisted provenance.
status reads that catalog and the latest bounded refresh result, never logs.
Defaults: 8 MiB native bytes and 96 discovery candidates per refresh, at most
32 metadata retries and 64 source refreshes; each header reads at most 64 KiB
separately from the native byte budget. Routine calls throttle to 30 seconds;
--force and generation handoffs bypass that throttle. Refresh has a two-second
deadline, and vendor SQLite queries have a 0.2-second execution deadline.
"""

import argparse
import datetime as dt
import fcntl
import heapq
import importlib.util
import json
import os
from pathlib import Path
import re
import signal
import sqlite3
import stat
import sys
import time

MODULE = importlib.util.spec_from_file_location("usage_ledger", Path(__file__).with_name("fm-usage-ledger.py"))
ledger = importlib.util.module_from_spec(MODULE)
MODULE.loader.exec_module(ledger)
METADATA_BYTES = 0


class Deadline(Exception):
    pass


def load(path, default):
    try:
        return json.loads(path.read_text())
    except FileNotFoundError:
        return default


def save(path, value):
    tmp = path.with_name(path.name + ".tmp")
    fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC | getattr(os, "O_NOFOLLOW", 0), 0o600)
    with os.fdopen(fd, "w") as out:
        json.dump(value, out, sort_keys=True, separators=(",", ":"))
        out.write("\n")
    os.replace(tmp, path)


def readonly(path):
    db = sqlite3.connect(Path(path).absolute().as_uri() + "?mode=ro", uri=True, timeout=0.1)
    db.row_factory = sqlite3.Row
    # Expensive/unindexed vendor queries must not stall supervision.
    stop = time.monotonic() + 0.2
    db.set_progress_handler(lambda: int(time.monotonic() > stop), 1000)
    return db


def generation(meta):
    fields = {}
    # Never retain arbitrary meta fields (including account pins or brief text).
    for line in meta.read_text().splitlines():
        k, sep, value = line.partition("=")
        if sep and k in ("spawn_gen", "worktree", "harness", "kind", "branch", "project"):
            if k in fields:
                return None
            fields[k] = value
    match = re.fullmatch(r"s([0-9]+)\.[0-9]+\.[0-9]+", fields.get("spawn_gen", ""))
    if not match or not Path(fields.get("worktree", "")).is_absolute():
        return None
    return dict(task=ledger.label(meta.stem), task_kind=ledger.label(fields.get("kind")),
                harness=ledger.label(fields.get("harness")), cwd=fields["worktree"],
                project_path=fields.get("project"), branch=fields.get("branch"),
                start=int(match[1]), end=None, generation=fields["spawn_gen"])


def snapshot(catalog, state, retire, gaps):
    now = time.time()
    current = set()
    for meta in state.glob("*.meta"):
        g = generation(meta)
        if not g or not g["task"]:
            gaps.add("task_generation_unavailable")
            continue
        if g["task_kind"] == "secondmate":
            continue  # Never inspect a secondmate home or its endpoint namespace.
        key = ledger.identity(g["task"], g["generation"])
        current.add(key)
        catalog["generations"].setdefault(key, g)
        if g["task"] == retire:
            catalog["generations"][key]["end"] = now
    for key, g in catalog["generations"].items():
        if key not in current and g["end"] is None:
            g["end"] = now


def pipeline_scopes(g, gaps, catalog):
    """Only native logs of pipeline-owned copies; spend deltas stay with their owner."""
    root = Path(os.environ.get("NM_HOME", str(Path.home() / ".no-mistakes")))
    if not root.is_absolute():
        root = Path(g["cwd"]) / root
    try:
        with readonly(root / "state.sqlite") as db:
            rows = db.execute(
                "select r.id,r.worktree_dir,r.created_at from runs r join repos p on p.id=r.repo_id "
                "where p.working_path=? and r.branch=? and r.created_at>=? "
                "and (? is null or r.created_at<?) and r.id>? "
                "order by r.id limit 17",
                (g["project_path"], g["branch"], g["start"], g["end"], g["end"],
                 catalog.setdefault("pipeline_cursors", {}).get(g["generation"], ""))).fetchall()
        catalog["pipeline_cursors"][g["generation"]] = rows[-1]["id"] if len(rows) == 17 else ""
        if len(rows) == 17:
            gaps.add("pipeline_discovery_backlog")
        scopes = []
        for r in rows:
            if r["worktree_dir"] and Path(r["worktree_dir"]).is_absolute():
                if r["worktree_dir"] == g["cwd"]:
                    gaps.add("pipeline_shares_worker_cwd_activity_unknown")
                else:
                    scopes.append(dict(g, cwd=r["worktree_dir"], start=r["created_at"], end=None,
                                       activity="validation", harness=None))
        return scopes
    except (sqlite3.Error, OSError):
        gaps.add("pipeline_native_scope_unavailable")
        return []


def header(path, harness):
    global METADATA_BYTES
    # A bounded metadata prefix is read in place; no body persisted.
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
    with os.fdopen(fd, "rb") as stream:
        if not stat.S_ISREG(os.fstat(stream.fileno()).st_mode):
            raise ValueError("nonregular_source")
        remaining = 65536
        while remaining > 0:
            line = stream.readline(remaining + 1)
            remaining -= len(line)
            METADATA_BYTES += len(line)
            if remaining < 0 or not line.endswith(b"\n"):
                return None
            row = json.loads(line)
            if harness == "codex":
                if row.get("type") != "session_meta":
                    return None
                row = row.get("payload", {})
            elif harness == "pi" and (row.get("type") != "session" or row.get("version") != 3):
                return None
            native = row.get("id") if harness != "claude" else row.get("sessionId")
            when = ledger.timestamp(row.get("timestamp"))
            if native and when and isinstance(row.get("cwd"), str):
                return row["cwd"], dt.datetime.fromisoformat(when.replace("Z", "+00:00")).timestamp(), ledger.identity(native)
            if harness != "claude":
                return None
    return None


def discovery_cursor(scope, harness, catalog):
    key = ledger.identity(scope["cwd"], harness, scope["start"], scope["task"], scope["activity"])
    return catalog["discovery"].setdefault(key, {})


def file_signature(path):
    st = os.stat(path, follow_symlinks=False)
    return [st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns, st.st_ctime_ns]


def candidates(scope, harness, catalog, limit, gaps):
    cwd = scope["cwd"]
    cursor = discovery_cursor(scope, harness, catalog)

    def unknown(path):
        if not isinstance(path, str) or not Path(path).is_absolute():
            return True
        sid = ledger.identity(os.path.abspath(path))
        if sid in catalog["sources"] or sid in catalog["retry"]:
            return False
        rejected = cursor.get("rejected", {}).get(sid)
        if rejected is not None:
            try:
                return rejected != file_signature(path)
            except OSError:
                return True
        return True

    if harness == "codex":
        root = Path(os.environ.get("CODEX_HOME", str(Path.home() / ".codex")))
        try:
            with readonly(root / "state_5.sqlite") as db:
                rows = []
                for row in db.execute("select id,rollout_path from threads where cwd=? and id>? order by id",
                                      (cwd, cursor.get("after", ""))):
                    if unknown(row["rollout_path"]):
                        rows.append(row)
                        if len(rows) == limit:
                            break
            cursor["after"] = rows[-1]["id"] if len(rows) == limit else ""
            if len(rows) == limit:
                gaps.add("discovery_backlog")
            return [r["rollout_path"] for r in rows]
        except (sqlite3.Error, OSError):
            gaps.add("codex_native_index_unavailable")
            return []
    if harness == "pi":
        root = Path(os.environ.get("PI_CODING_AGENT_DIR", str(Path.home() / ".pi/agent"))) / "sessions"
        directory = root / ("--" + re.sub(r"[/\\:]", "-", cwd.lstrip("/\\")) + "--")
    else:
        root = Path(os.environ.get("CLAUDE_CONFIG_DIR", str(Path.home() / ".claude"))) / "projects"
        directory = root / re.sub(r"[^a-zA-Z0-9]", "-", cwd)
    try:
        stamp = directory.stat().st_mtime_ns
        if cursor.get("stamp") != stamp:
            cursor.update(stamp=stamp, after="")
        # Metadata-only enumeration of ONE exact cwd store, never unrelated logs.
        with os.scandir(directory) as entries:
            names = heapq.nsmallest(limit, (e.name for e in entries if e.name.endswith(".jsonl")
                                           and e.name > cursor.get("after", "") and e.is_file(follow_symlinks=False)
                                           and unknown(e.path)))
        if len(names) < limit:
            cursor["after"] = ""
        else:
            cursor["after"] = names[-1]
            gaps.add("discovery_backlog")
        return [str(directory / name) for name in names]
    except OSError:
        gaps.add(harness + "_native_store_unavailable")
        return []


def rotate(items, catalog, key, limit):
    start = catalog.get(key, 0) % max(1, len(items))
    selected = (items + items)[start:start + min(limit, len(items))]
    catalog[key] = (start + len(selected)) % max(1, len(items))
    return selected


def scope_batch(scopes, catalog, key, limit):
    active = [s for s in scopes if s["end"] is None]
    ended = [s for s in scopes if s["end"] is not None]
    selected = rotate(active, catalog, key, limit - bool(ended))
    return selected + rotate(ended, catalog, key + "_ended", limit - len(selected))


def refresh(args, store, catalog):
    gaps = set()
    state = Path(os.environ.get("FM_STATE_OVERRIDE", str(args.home / "state")))
    pending = list((store / "pending").glob("*.json"))
    for path in pending:
        g = load(path, None)
        if g:
            key = ledger.identity(g["task"], g["generation"])
            old = catalog["generations"].get(key)
            if old is None or (g["end"] is not None and old["end"] is None):
                catalog["generations"][key] = g
    snapshot(catalog, state, args.retire, gaps)
    # Joins survive cleanup/relaunch. Persist BEFORE any bounded discovery work.
    save(store / "catalog.json", catalog)
    for path in pending:
        path.unlink(missing_ok=True)
    scopes = [dict(cwd=str(args.home), start=0, end=None, task="firstmate", task_kind="supervisor",
                   harness=None, activity="supervisor")]
    generations = list(catalog["generations"].values())
    pipeline = catalog.setdefault("pipeline_scopes", {})
    for p in pipeline.values():
        if p["end"] is not None:
            for harness in ledger.MAPS:
                discovery_cursor(p, harness, catalog).pop("rejected", None)
            p["end"] = None
    chosen = scope_batch(generations, catalog, "pipeline_cursor", 4)
    if len(generations) > len(chosen):
        gaps.add("pipeline_scope_discovery_backlog")
    for g in chosen:
        for p in pipeline_scopes(g, gaps, catalog):
            pipeline[ledger.identity(p["generation"], p["cwd"], p["start"])] = p
    for g in generations:
        scopes.append(dict(g, activity="worker"))
        if g["harness"] not in ledger.MAPS:
            gaps.add("unsupported_worker_reader_" + (g["harness"] or "unknown"))
    scopes.extend(pipeline.values())
    # Scope rotation prevents a long fleet/history from starving later scopes.
    selected = scope_batch(scopes, catalog, "scope_cursor", 8)
    if len(scopes) > len(selected):
        gaps.add("scope_discovery_backlog")
    remaining = args.max_candidates
    for scope in selected:
        for harness in ledger.MAPS:
            if scope["harness"] and scope["harness"] != harness:
                continue
            if remaining <= 0:
                gaps.add("discovery_backlog")
                break
            paths = candidates(scope, harness, catalog, min(32, max(1, remaining // len(ledger.MAPS))), gaps)
            remaining -= len(paths)
            for path in paths:
                if not isinstance(path, str) or not Path(path).is_absolute() or not path.endswith(".jsonl"):
                    gaps.add("invalid_native_locator")
                    continue
                sid = ledger.identity(os.path.abspath(path))
                try:
                    signature = file_signature(path)
                    native = header(path, harness)
                    if native is None:
                        # Retry partial headers even if directory mtime stays unchanged.
                        catalog["retry"][sid] = dict(path=path, harness=harness, scope=scope)
                        gaps.add("native_metadata_unavailable")
                        continue
                    cwd, created, run = native
                    if cwd != scope["cwd"] or created < scope["start"] or (
                            scope["end"] is not None and created >= scope["end"]):
                        discovery_cursor(scope, harness, catalog).setdefault("rejected", {})[sid] = signature
                        continue
                    catalog.setdefault("proofs", {})[sid] = dict(cwd=cwd, created=created, run=run)
                    catalog["sources"][sid] = dict(harness=harness, path=path, task=scope["task"],
                        task_kind=scope["task_kind"], activity=scope["activity"])
                    catalog["retry"].pop(sid, None)
                except (OSError, ValueError, TypeError, AttributeError):
                    catalog["retry"][sid] = dict(path=path, harness=harness, scope=scope)
                    gaps.add("native_metadata_unavailable")
    # Retry only bounded partial headers, no transcript history or new timer.
    retries = list(catalog["retry"].items())
    selected_retries = rotate(retries, catalog, "retry_cursor", 32)
    for sid, pending in selected_retries:
        try:
            native = header(pending["path"], pending["harness"])
            scope = pending["scope"]
            if scope["activity"] == "validation":
                scope = dict(scope, end=None)
            elif scope.get("generation"):
                retained = catalog["generations"].get(ledger.identity(scope["task"], scope["generation"]))
                if retained:
                    scope = dict(scope, end=retained["end"])
            if native is not None:
                cwd, created, run = native
                if cwd == scope["cwd"] and created >= scope["start"] and (
                        scope["end"] is None or created < scope["end"]):
                    catalog.setdefault("proofs", {})[sid] = dict(cwd=cwd, created=created, run=run)
                    catalog["sources"][sid] = dict(harness=pending["harness"], path=pending["path"],
                        task=scope["task"], task_kind=scope["task_kind"], activity=scope["activity"])
                del catalog["retry"][sid]
        except (OSError, ValueError, TypeError, AttributeError):
            gaps.add("native_metadata_unavailable")
    if catalog["retry"]:
        gaps.add("native_metadata_unavailable")
        if len(catalog["retry"]) > len(selected_retries):
            gaps.add("metadata_retry_backlog")
    specs = list(catalog["sources"].values())
    with ledger.database(store / "usage.sqlite") as db:
        db.execute("BEGIN IMMEDIATE")
        saved_sources = {row["id"]: json.loads(row["data"]) for row in db.execute("select id,data from sources")}
        changed = []
        for spec in specs:
            sid = ledger.identity(os.path.abspath(spec["path"]))
            saved = saved_sources.get(sid, {})
            try:
                st = os.stat(spec["path"], follow_symlinks=False)
                if not stat.S_ISREG(st.st_mode):
                    gaps.add("source_missing_or_unreadable")
                    continue
                if (saved.get("harness") == spec["harness"]
                        and saved.get("joins") == {k: spec.get(k) for k in ledger.JOINS}
                        and saved.get("file") == [st.st_dev, st.st_ino]
                        and saved.get("offset") == st.st_size and saved.get("mtime_ns") == st.st_mtime_ns
                        and saved.get("ctime_ns") == st.st_ctime_ns and not saved.get("current")):
                    continue
            except OSError:
                gaps.add("source_missing_or_unreadable")
                continue
            changed.append(spec)
        batch = rotate(changed, catalog, "source_cursor", 64)
        if len(changed) > len(batch):
            gaps.add("source_refresh_backlog")
        verified = []
        for spec in batch:
            sid = ledger.identity(os.path.abspath(spec["path"]))
            try:
                proof = catalog.get("proofs", {}).get(sid)
                native = header(spec["path"], spec["harness"])
                if native is not None and proof == dict(cwd=native[0], created=native[1], run=native[2]):
                    verified.append(spec)
                else:
                    gaps.add("source_metadata_changed_or_unavailable")
            except (OSError, ValueError, TypeError, AttributeError):
                gaps.add("source_missing_or_unreadable")
        save(store / "catalog.json", catalog)
        result = ledger.collect(db, verified, args.max_bytes, usage_only=True)
        source_gaps = db.execute("select data from sources").fetchall()
        for row in source_gaps:
            gaps.update(json.loads(row[0]).get("current", []))
            gaps.update(json.loads(row[0]).get("gaps", []))
    if not specs:
        gaps.add("no_native_sources_observed_usage_unknown")
    result.update(coverage="partial", metadata_bytes_read=METADATA_BYTES, gaps=sorted(gaps), known_sources=len(specs),
                  observed_at=time.time(), enabled=True, pipeline_counters="separate_fm_pipeline_spend_owner")
    return result


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("command", choices=("refresh", "status"))
    parser.add_argument("--home", type=Path, default=os.environ.get("FM_HOME"))
    parser.add_argument("--store", type=Path)
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--retire")
    parser.add_argument("--remember")
    parser.add_argument("--max-bytes", type=int, default=8 * 1024 * 1024)
    parser.add_argument("--max-candidates", type=int, default=96)
    args = parser.parse_args()
    if args.home is None or not args.home.is_absolute():
        parser.error("explicit absolute --home or FM_HOME is required")
    store = args.store or Path(os.environ.get("FM_DATA_OVERRIDE", str(args.home / "data"))) / "usage-ledger"
    config = Path(os.environ.get("FM_CONFIG_OVERRIDE", str(args.home / "config")))
    try:
        disabled = (config / "usage-ledger").exists() and (config / "usage-ledger").read_text().strip() == "off"
        if disabled:
            print(ledger.packed(dict(enabled=False, coverage="disabled_usage_unknown")))
            return 0
        if args.command == "status":
            print(ledger.packed(load(store / "status.json", dict(enabled=True, gaps=["not_yet_refreshed_usage_unknown"])))); return 0
        if args.max_bytes <= ledger.MAX_LINE or not 1 <= args.max_candidates <= 256:
            raise ValueError("invalid automatic scan budget")
        store.mkdir(mode=0o700, parents=True, exist_ok=True)
        os.chmod(store, 0o700)
        if args.retire or args.remember:
            task = args.retire or args.remember
            if ledger.label(task) != task or "/" in task or task.startswith("."):
                raise ValueError("invalid task identity")
            state = Path(os.environ.get("FM_STATE_OVERRIDE", str(args.home / "state")))
            g = generation(state / (task + ".meta"))
            if g and g["task_kind"] != "secondmate":
                g["end"] = time.time() if args.retire else None
                pending = store / "pending"
                pending.mkdir(mode=0o700, exist_ok=True)
                # Independent atomic handoff survives an overlapping refresh and cleanup.
                save(pending / (ledger.identity(task, g["generation"], g["end"]) + ".json"), g)
        fd = os.open(store / ".lock", os.O_WRONLY | os.O_CREAT | getattr(os, "O_NOFOLLOW", 0), 0o600)
        with os.fdopen(fd, "w") as lock:
            try:
                fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
            except BlockingIOError:
                print(ledger.packed(dict(enabled=True, deferred="overlapping_refresh"))); return 0
            previous = load(store / "status.json", {})
            if not args.force and not args.retire and not args.remember and time.time() - previous.get("observed_at", 0) < 30:
                return 0
            catalog = load(store / "catalog.json", dict(generations={}, sources={}, discovery={}, retry={}))
            signal.signal(signal.SIGALRM, lambda *_: (_ for _ in ()).throw(Deadline()))
            signal.setitimer(signal.ITIMER_REAL, 2)
            wall, cpu = time.monotonic(), time.process_time()
            try:
                result = refresh(args, store, catalog)
                result.update(wall_seconds=time.monotonic()-wall, cpu_seconds=time.process_time()-cpu)
            except (OSError, ValueError, sqlite3.Error, Deadline):
                result = dict(enabled=True, coverage="partial", gaps=["automatic_refresh_failed_or_deadline"],
                              observed_at=time.time())
            finally:
                signal.setitimer(signal.ITIMER_REAL, 0)
            save(store / "status.json", result)
            print(ledger.packed(result))
            return 1 if "automatic_refresh_failed_or_deadline" in result["gaps"] else 0
    except (OSError, ValueError, sqlite3.Error):
        print("fm-usage-ledger: automatic local accounting unavailable; usage unknown", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
