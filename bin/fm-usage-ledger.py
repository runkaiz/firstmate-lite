#!/usr/bin/env python3
"""On-demand native usage accounting; see docs/usage-ledger.md for the contract.

Usage: fm-usage-ledger.py collect --manifest FILE --db FILE [--max-bytes N]
       fm-usage-ledger.py summary --db FILE [--group-by FIELD,...]
           [--since RFC3339 --until RFC3339] [--text]
       fm-usage-ledger.py coverage

No defaults discover sources or activate collection. Only collect writes a ledger.
Python 3 standard library only. Source files must be explicitly selected JSONL.
"""

import argparse
import datetime as dt
import hashlib
import json
import math
import os
from pathlib import Path
import re
import sqlite3
import stat
import sys


VERSION = 1
MAX_LINE = 4 * 1024 * 1024
FIELDS = ("input", "output", "cache_read", "cache_write", "reasoning", "total")
JOINS = ("project", "task", "task_kind", "activity")
GROUPS = JOINS + ("harness", "model", "run", "turn", "day")
MAPS = {
    "claude": dict(zip(FIELDS, ("input_tokens", "output_tokens",
                   "cache_read_input_tokens", "cache_creation_input_tokens", None, None))),
    "codex": dict(zip(FIELDS, ("input_tokens", "output_tokens", "cached_input_tokens",
                  "cache_write_input_tokens", "reasoning_output_tokens", "total_tokens"))),
    "pi": dict(zip(FIELDS, ("input", "output", "cacheRead", "cacheWrite", "reasoning", "totalTokens"))),
}
UNAVAILABLE = ("opencode", "pi-signed", "grok", "kimi", "cursor", "gemini",
               "muse", "rovo", "omp", "agy", "devin")


def packed(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), allow_nan=False)


def identity(*parts):
    return hashlib.sha256(packed(parts).encode()).hexdigest()


def label(value):
    return value if isinstance(value, str) and re.fullmatch(r"[\w./:@+-]{1,120}", value, re.ASCII) else None


def timestamp(value):
    if not isinstance(value, str):
        return None
    try:
        date = dt.datetime.fromisoformat(value.replace("Z", "+00:00"))
        if date.tzinfo is None:
            return None
        return date.astimezone(dt.timezone.utc).isoformat().replace("+00:00", "Z")
    except ValueError:
        return None


def number(value):
    return value if type(value) in (int, float) and math.isfinite(value) and value >= 0 else None


def counters(harness, usage):
    return {k: number(usage.get(k)) for k in MAPS[harness].values()
            if k and number(usage.get(k)) is not None}


def coverage():
    return {
        "schema_version": VERSION,
        "readers": {h: {"source": s, "reported_counter_map": MAPS[h],
                         "tools": "native call id/name; status/duration only if recorded",
                         "joins": "manifest labels; native run/turn when present",
                         "live_schema": "unverified" if h == "claude" else "keys inspected only"}
                    for h, s in (("claude", "assistant message JSONL"),
                                 ("codex", "rollout JSONL"), ("pi", "session v3 JSONL"))},
        "unavailable_readers": {h: "no validated local reader; all fields unavailable" for h in UNAVAILABLE},
        "always_unavailable": ["exact per-tool billed tokens", "logical subprocess attribution",
                               "subscription marginal cost", "unrecorded requests or tools"],
        "existing_owners": {"no-mistakes": "bin/fm-pipeline-spend.sh (never add to this ledger)",
                            "trace": "bin/fm-trace-context-lib.sh (identity only)",
                            "timing": "bin/fm-timing-lib.sh (elapsed time only)"},
    }


def database(path, readonly=False):
    if readonly:
        db = sqlite3.connect(Path(path).resolve().as_uri() + "?mode=ro", uri=True, timeout=5)
    else:
        # Do not chmod or overwrite another application's database.
        if not Path(path).exists():
            fd = os.open(path, os.O_CREAT | os.O_EXCL | os.O_WRONLY, 0o600)
            os.close(fd)
        db = sqlite3.connect(path, timeout=5)
    db.row_factory = sqlite3.Row
    tables = {r[0] for r in db.execute("select name from sqlite_master where type='table'")}
    if tables and "usage_ledger_version" not in tables:
        db.close()
        raise ValueError("destination is not a usage ledger")
    if readonly:
        if not tables:
            raise ValueError("empty ledger")
    else:
        db.executescript("""
        CREATE TABLE IF NOT EXISTS usage_ledger_version (version INTEGER);
        CREATE TABLE IF NOT EXISTS sources (id TEXT PRIMARY KEY, data TEXT NOT NULL);
        CREATE TABLE IF NOT EXISTS events (id TEXT PRIMARY KEY, data TEXT NOT NULL);
        """)
        if db.execute("select count(*) from usage_ledger_version").fetchone()[0] == 0:
            db.execute("insert into usage_ledger_version values (?)", (VERSION,))
            db.commit()
    if db.execute("select version from usage_ledger_version").fetchone()[0] != VERSION:
        raise ValueError("unsupported ledger version")
    return db


class Reader:
    def __init__(self, db, spec, saved):
        self.db, self.harness, self.spec = db, spec["harness"], spec
        self.state = saved
        self.state.setdefault("gaps", [])
        self.state.setdefault("run", None)
        self.state.setdefault("turn", None)
        self.state.setdefault("model", None)

    def gap(self, reason):
        if reason not in self.state["gaps"]:
            self.state["gaps"].append(reason)

    def put(self, kind, native, when, **values):
        event = dict(kind=kind, harness=self.harness, run=self.state["run"],
                     turn=self.state["turn"], model=self.state["model"], timestamp=timestamp(when))
        event.update({k: self.spec.get(k) for k in JOINS})
        event.update(values)
        key = identity(self.harness, kind, native)
        old = self.db.execute("select data from events where id=?", (key,)).fetchone()
        if old:
            previous = json.loads(old[0])
            # Duplicate copies/forks retain first attribution, never create new usage.
            if kind == "usage":
                merged = dict(previous["raw"])
                for k, v in values["raw"].items():
                    merged[k] = max(v, merged.get(k, 0))
                previous["raw"] = merged
                for k, v in values["tokens"].items():
                    if v is not None:
                        previous["tokens"][k] = max(v, previous["tokens"].get(k) or 0)
            else:
                for k in ("status", "duration_ms"):
                    if values.get(k) is not None:
                        previous[k] = values[k]
            event = previous
        self.db.execute("insert or replace into events values (?,?)", (key, packed(event)))

    def usage(self, native, when, raw, normalized=None, basis="native_message"):
        raw = counters(self.harness, raw)
        if not raw:
            self.gap("usage_fields_unavailable")
            return
        self.put("usage", native, when, raw=raw,
                 tokens=normalized or {f: raw.get(MAPS[self.harness][f]) for f in FIELDS},
                 basis=basis)

    def tool(self, native, when, name=None, status=None, duration=None, is_call=False):
        if getattr(self, "usage_only", False):
            return
        if not isinstance(native, str) or not native:
            self.gap("tool_id_unavailable")
            return
        # Results do not become calls if the call itself was not observed.
        if name is None and not is_call:
            key = identity(self.harness, "tool", native)
            if not self.db.execute("select 1 from events where id=?", (key,)).fetchone():
                self.gap("tool_result_without_call")
                return
        self.put("tool", native, when, name=label(name),
                 status=status if status in ("success", "error", "completed", "in_progress", "failed") else None,
                 duration_ms=number(duration))

    def read(self, row):
        h, t = self.harness, row.get("type")
        when = row.get("timestamp")
        if h == "codex":
            self.codex(row, t, when)
            return
        if h == "pi" and t == "session":
            if row.get("version") != 3:
                self.gap("unsupported_pi_session_version")
                self.state["unsupported"] = True
            self.state["run"] = identity(row.get("id")) if row.get("id") else None
            return
        if self.state.get("unsupported"):
            return
        if h == "pi" and t in ("usage", "compaction", "branch_summary"):
            if isinstance(row.get("usage"), dict) and row.get("id"):
                self.state["model"] = label(row.get("model"))
                if self.state["model"] is None:
                    self.gap("pi_auxiliary_usage_model_unknown")
                self.usage([row["id"], when], when, row["usage"])
            elif t in ("compaction", "branch_summary"):
                self.gap("pi_auxiliary_usage_unavailable")
            return
        m = row.get("message")
        if not isinstance(m, dict):
            return
        if h == "claude":
            if row.get("sessionId"):
                self.state["run"] = identity(row["sessionId"])
            if m.get("role") == "user" and row.get("uuid"):
                self.state["turn"] = identity(row["uuid"])
        elif m.get("role") == "user" and row.get("id"):
            self.state["turn"] = identity(row["id"], when)
        if m.get("role") == "assistant":
            self.state["model"] = label(m.get("model"))
            native = m.get("id") if h == "claude" else row.get("id")
            if not native:
                self.gap("usage_identity_unavailable")
            elif isinstance(m.get("usage"), dict):
                # Pi's short entry IDs need their original timestamp to avoid collisions.
                key = native if h == "claude" else [native, when]
                self.usage(key, when, m["usage"])
            else:
                self.gap("assistant_usage_unavailable")
        if h == "pi" and m.get("role") == "toolResult" and isinstance(m.get("usage"), dict):
            # Nested model work has no authoritative physical model on this message.
            self.state["model"] = None
            self.gap("pi_nested_usage_model_unknown")
            if row.get("id"):
                self.usage([row["id"], when], when, m["usage"])
            else:
                self.gap("usage_identity_unavailable")
        content = m.get("content")
        if isinstance(content, list):
            for block in content:
                if not isinstance(block, dict):
                    continue
                if block.get("type") in ("tool_use", "toolCall"):
                    self.tool(block.get("id"), when, block.get("name"), is_call=True)
                elif block.get("type") == "tool_result":
                    self.tool(block.get("tool_use_id"), when,
                              status="error" if block.get("is_error") else "success")
        if m.get("role") == "toolResult":
            self.tool(m.get("toolCallId"), when,
                      status=("error" if m["isError"] else "success") if "isError" in m else None,
                      duration=m.get("durationMs"))

    def codex(self, row, t, when):
        p = row.get("payload")
        if not isinstance(p, dict):
            return
        if t == "session_meta":
            self.state["run"] = identity(p.get("id")) if p.get("id") else None
        elif t == "turn_context":
            self.state["model"] = label(p.get("model"))
            self.state["turn"] = identity(p["turn_id"]) if p.get("turn_id") else None
        elif t == "response_item":
            if p.get("type") in ("function_call", "custom_tool_call"):
                self.tool(p.get("call_id"), when, p.get("name"), p.get("status"), is_call=True)
            elif p.get("type") in ("function_call_output", "custom_tool_call_output"):
                self.tool(p.get("call_id"), when, status=p.get("status"))
        elif t == "event_msg" and p.get("type") == "token_count":
            info = p.get("info")
            if not isinstance(info, dict) or not isinstance(info.get("total_token_usage"), dict):
                self.gap("codex_cumulative_unavailable")
                return
            total = counters("codex", info["total_token_usage"])
            previous = self.state.get("cumulative")
            if total == previous:
                return  # Native refresh, not another request.
            last = counters("codex", info.get("last_token_usage") or {})
            delta = last
            basis = "native_last_request"
            attribution_unknown = False
            if previous and all(k in previous and v >= previous[k] for k, v in total.items()):
                delta = {k: v - previous[k] for k, v in total.items()}
                basis = "native_cumulative_delta"
                if any(k in last and v != last[k] for k, v in delta.items()):
                    self.gap("cumulative_delta_spans_unobserved_requests")
                    attribution_unknown = True
            elif previous:
                self.gap("cumulative_reset_or_compaction")
            elif total != last:
                self.gap("earlier_cumulative_usage_unattributed")
            self.state["cumulative"] = total
            if not timestamp(when) or not self.state["run"]:
                self.gap("usage_identity_unavailable")
                return
            # Retained replay rows in fork/copy logs have the same timestamp and total.
            native = [timestamp(when), total]
            model, turn = self.state.get("model"), self.state.get("turn")
            if attribution_unknown:
                self.state["model"], self.state["turn"] = None, None
            self.usage(native, None if attribution_unknown else when, total,
                       {f: delta.get(MAPS["codex"][f]) for f in FIELDS}, basis)
            self.state["model"], self.state["turn"] = model, turn


def manifest(path):
    with open(path, encoding="utf-8") as stream:
        specs = json.load(stream)
    if not isinstance(specs, list) or len(specs) > 256:
        raise ValueError("manifest must be a list of at most 256 selected files")
    seen = set()
    for spec in specs:
        if not isinstance(spec, dict) or set(spec) - {"harness", "path", *JOINS}:
            raise ValueError("invalid manifest entry")
        if spec.get("harness") not in MAPS or not isinstance(spec.get("path"), str):
            raise ValueError("unsupported reader or missing path; see coverage")
        p = Path(spec["path"])
        if not p.is_absolute() or p.suffix != ".jsonl" or any(c in spec["path"] for c in "*?["):
            raise ValueError("select an absolute JSONL file, without globs")
        if any(k in spec and label(spec[k]) != spec[k] for k in JOINS):
            raise ValueError("joins must be minimal identifier labels")
        sid = identity(os.path.abspath(p))
        if sid in seen:
            raise ValueError("duplicate manifest path")
        seen.add(sid)
    return specs


def anchor(stream, offset):
    stream.seek(max(0, offset - 256))
    return hashlib.sha256(stream.read(min(offset, 256))).hexdigest()


def collect(db, specs, budget, usage_only=False):
    read_bytes = 0
    for spec in specs:
        sid = identity(os.path.abspath(spec["path"]))
        row = db.execute("select data from sources where id=?", (sid,)).fetchone()
        saved = json.loads(row[0]) if row else {}
        joins = {k: spec.get(k) for k in JOINS}
        if saved and (saved["harness"] != spec["harness"] or saved["joins"] != joins):
            raise ValueError("source reader/joins changed; use a separate ledger")
        reader = Reader(db, spec, saved)
        reader.usage_only = usage_only
        reader.gap("selected_logs_only_not_a_billing_export")
        saved.update(harness=spec["harness"], joins=joins, current=[])
        try:
            # No symlink/FIFO/device reads; never wait on a writer-owned stream.
            fd = os.open(spec["path"], os.O_RDONLY | os.O_NONBLOCK | getattr(os, "O_NOFOLLOW", 0))
            with os.fdopen(fd, "rb") as stream:
                st = os.fstat(stream.fileno())
                if not stat.S_ISREG(st.st_mode):
                    raise ValueError("source must be a regular file")
                offset = saved.get("offset", 0)
                if saved.get("file") != [st.st_dev, st.st_ino] or st.st_size < offset or (
                        offset and anchor(stream, offset) != saved.get("anchor")):
                    if row:
                        reader.gap("rotation_or_rewrite_rescanned")
                    offset = 0
                    for k in ("run", "turn", "model"):
                        saved[k] = None
                    for k in ("cumulative", "unsupported"):
                        saved.pop(k, None)
                stream.seek(offset)
                while stream.tell() < st.st_size and read_bytes < budget:
                    start = stream.tell()
                    line = stream.readline(min(MAX_LINE + 1, budget - read_bytes))
                    read_bytes += len(line)
                    if not line.endswith(b"\n"):
                        stream.seek(start)
                        saved["current"].append("partial_line_or_scan_budget")
                        if len(line) > MAX_LINE:
                            reader.gap("record_exceeds_4MiB_limit")
                        break
                    offset = stream.tell()
                    try:
                        record = json.loads(line)
                        if isinstance(record, dict):
                            reader.read(record)
                        else:
                            reader.gap("invalid_record_shape")
                    except (ValueError, TypeError, AttributeError, RecursionError):
                        reader.gap("malformed_or_unknown_record")
                if offset < st.st_size:
                    saved["current"].append("unread_bytes")
                saved.update(offset=offset, file=[st.st_dev, st.st_ino], anchor=anchor(stream, offset),
                             mtime_ns=st.st_mtime_ns, ctime_ns=st.st_ctime_ns)
        except OSError:
            saved["current"].append("source_missing_or_unreadable")
        saved.setdefault("offset", 0)
        db.execute("insert or replace into sources values (?,?)", (sid, packed(saved)))
    return {"schema_version": VERSION, "bytes_read": read_bytes, "selected_sources": len(specs)}


def summary(db, groups, since=None, until=None):
    aggregates = {}
    for row in db.execute("select id,data from events order by id"):
        event = json.loads(row["data"])
        ts = event["timestamp"]
        if (since or until) and (not ts or (since and ts < since) or (until and ts >= until)):
            continue
        key = tuple((ts[:10] if ts else None) if k == "day" else event.get(k) for k in groups)
        if key not in aggregates:
            aggregates[key] = {"group": dict(zip(groups, key)), "usage_records": 0, "tool_calls": 0,
                               "tokens": {f: {"reported": 0, "unknown_records": 0} for f in FIELDS},
                               "tools": {}, "raw_counter_totals": {}}
        a = aggregates[key]
        if event["kind"] == "usage":
            a["usage_records"] += 1
            # Raw cumulative counters are snapshots, deliberately never summed.
            if event["harness"] != "codex":
                for k, v in event["raw"].items():
                    a["raw_counter_totals"][k] = a["raw_counter_totals"].get(k, 0) + v
            for field, v in event["tokens"].items():
                if v is None:
                    a["tokens"][field]["unknown_records"] += 1
                else:
                    a["tokens"][field]["reported"] += v
        else:
            a["tool_calls"] += 1
            name = event.get("name") or "unknown"
            tool = a["tools"].setdefault(name, {"calls": 0, "status": {}, "duration_ms": 0,
                                                 "unknown_duration_calls": 0})
            tool["calls"] += 1
            status = event.get("status") or "unknown"
            tool["status"][status] = tool["status"].get(status, 0) + 1
            if event.get("duration_ms") is None:
                tool["unknown_duration_calls"] += 1
            else:
                tool["duration_ms"] += event["duration_ms"]
    sources = []
    for row in db.execute("select id,data from sources order by id"):
        s = json.loads(row["data"])
        sources.append({"source_id": row["id"], "harness": s["harness"],
                        "gaps": sorted(s["gaps"]), "current": sorted(set(s["current"]))})
    return {"schema_version": VERSION, "coverage": "partial", "pricing": None,
            "tool_token_allocation": None, "sources": sources,
            "groups": sorted(aggregates.values(), key=lambda a: packed(a["group"])),
            "empty_means": "no observed matching events; usage unknown"}


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    subs = parser.add_subparsers(dest="command", required=True)
    subs.add_parser("coverage")
    c = subs.add_parser("collect")
    c.add_argument("--manifest", required=True)
    c.add_argument("--db", required=True)
    c.add_argument("--max-bytes", type=int, default=16 * 1024 * 1024)
    s = subs.add_parser("summary")
    s.add_argument("--db", required=True)
    s.add_argument("--group-by", default="harness,model,project,task")
    s.add_argument("--since")
    s.add_argument("--until")
    s.add_argument("--text", action="store_true")
    args = parser.parse_args()
    try:
        if args.command == "coverage":
            result = coverage()
        elif args.command == "collect":
            if args.max_bytes < MAX_LINE + 1:
                raise ValueError("max-bytes must exceed the record limit (4194304)")
            specs = manifest(args.manifest)
            with database(args.db) as db:
                db.execute("BEGIN IMMEDIATE")
                result = collect(db, specs, args.max_bytes)
        else:
            groups = args.group_by.split(",")
            if not groups or any(k not in GROUPS for k in groups) or len(groups) != len(set(groups)):
                raise ValueError("invalid group-by field")
            since, until = timestamp(args.since), timestamp(args.until)
            if (args.since and not since) or (args.until and not until):
                raise ValueError("time bounds require an RFC3339 timezone")
            with database(args.db, readonly=True) as db:
                result = summary(db, groups, since, until)
            if args.text:
                print("Observed usage (partial coverage; no per-tool token allocation or price)")
                for a in result["groups"]:
                    print(packed(a["group"]), "requests/records:", a["usage_records"],
                          "tool calls:", a["tool_calls"], "tokens:", packed(a["tokens"]))
                print("Source gaps:", packed(result["sources"]))
                return 0
        print(packed(result))
        return 0
    except (OSError, ValueError, sqlite3.Error) as error:
        # Never print paths, bad source rows, JSON parse contexts, or SQL payloads.
        print("fm-usage-ledger: " + (str(error) if type(error) is ValueError else
                                     "local I/O or ledger operation failed"), file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
