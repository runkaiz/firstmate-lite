# Local usage ledger

`bin/fm-usage-ledger.py` reads explicitly selected native JSONL files on demand with Python 3's standard library.
It has no startup attachment, background process, automatic home search, configuration switch, network access, credential input, pricing lookup, or agent invocation.
Collection remains inactive until an operator deliberately invokes `collect` with a manifest and destination database.
The collector never modifies native logs or no-mistakes state.

## Invocation

Create a private manifest outside the repository with one entry per selected regular file:

```json
[
  {
    "harness": "pi",
    "path": "/absolute/path/to/selected-session.jsonl",
    "project": "example",
    "task": "trial-01",
    "task_kind": "ship",
    "activity": "tool-comparison"
  }
]
```

The four labels are optional identifiers supplied by the operator, never classifications inferred from conversation text.
Omitted labels remain unknown.
Use minimal labels rather than task descriptions or private report text.
Select only usage-bearing native logs, never credentials, configuration exports, or arbitrary private documents.
The manifest is the operator's explicit local read selection; syntax validation cannot prove a JSONL file contains no credentials.
No paths, cwd, account IDs, prompts, arguments, tool outputs, cost objects, custom metadata, or text bodies are retained by the parser.
Native event/run IDs and source paths become SHA-256 identifiers; model and surfaced tool names, timestamps, numeric counters, and those four labels remain readable.
Hashes are correlation identifiers rather than anonymization against a local adversary who already knows the source paths.

```sh
python3 bin/fm-usage-ledger.py coverage
python3 bin/fm-usage-ledger.py collect --manifest /private/selected.json --db /private/usage.sqlite
python3 bin/fm-usage-ledger.py summary --db /private/usage.sqlite
python3 bin/fm-usage-ledger.py summary --db /private/usage.sqlite --group-by harness,model,task,turn --text
python3 bin/fm-usage-ledger.py summary --db /private/usage.sqlite --group-by day,activity --since 2026-10-01T00:00:00Z --until 2026-11-01T00:00:00Z
```

Use a private directory; a new ledger file is mode 0600.
Do not use an existing application's database as the destination.
`summary` opens the ledger read-only and never reads source files.
Time bounds are inclusive at the start and exclusive at the end, in UTC; events without timestamps are excluded from bounded queries.
Repeat `collect` with the same manifest to read appended bytes.
The default scan budget is 16 MiB across the manifest, and `--max-bytes` sets a larger or smaller budget above the 4 MiB record limit.
Run again to continue a budget-limited scan; order short or active files first when selecting very large sources.
There is no scheduled retry.

## Local handoff and refresh

Keep the selected manifest and database in the operational home's private `data/` directory, separate from a disposable task worktree.
After the collector's branch has landed through the normal local landing path, invoke the installed script from that home's stable checkout:

```sh
umask 077
python3 /absolute/firstmate/bin/fm-usage-ledger.py collect --manifest /absolute/firstmate/data/usage/selected.json --db /absolute/firstmate/data/usage/usage.sqlite --max-bytes 67108864
python3 /absolute/firstmate/bin/fm-usage-ledger.py summary --db /absolute/firstmate/data/usage/usage.sqlite --group-by day,harness,model,task --text
```

Run this explicit refresh at a report or task outcome when updated measurements are wanted; it installs no schedule or global hook.
The manifest keeps following appended records in its selected files, but does not discover new sessions automatically.
Before adding a worker source, match native session metadata to both the recorded worktree and its current launch generation; a recycled worktree path alone does not establish task ownership.
Keep supervisor sources separately labelled, and retain the same attribution for previously selected sources.
At a new session or task generation, deliberately extend the manifest with proven sources or start a separate period ledger; never sum overlapping period ledgers without native-event deduplication.
Record the selected time window, source coverage, stale counters, unknown fields, and measured collector overhead beside each baseline.
An invocation from a temporary worker path proves collection only for that invocation; ongoing on-demand use requires the stable installed command and maintained selection above.

## Coverage matrix

“Reported” means a numeric field exists in a selected record, not a verified bill or complete account history.
Fields absent in a particular record stay unknown even when its harness supports them.
The `coverage` command exposes the field mappings and reader availability as JSON.

| Harness/source | Input/output | Cache read/write | Reasoning/total | Run/turn/time | Tools/status/duration | Current validation |
| --- | --- | --- | --- | --- | --- | --- |
| Claude assistant-message JSONL | `input_tokens`, `output_tokens` | `cache_read_input_tokens`, `cache_creation_input_tokens` | Unavailable | `sessionId`; user UUID; record timestamp | `tool_use.id/name`; `tool_result.is_error`; duration unavailable | Synthetic schema fixtures; no selected live Claude file available |
| Codex rollout JSONL | `token_count.info` native last/cumulative counters | `cached_input_tokens`, `cache_write_input_tokens` when present | `reasoning_output_tokens`, `total_tokens` when present | Session metadata ID; `turn_context.turn_id` when present; record timestamp | Function/custom call ID/name; explicit status only; duration unavailable | Local key shapes inspected; semantics regression uses synthetic fixtures |
| Pi session v3 JSONL | `message.usage.input/output` | `cacheRead`, `cacheWrite` | `reasoning`, `totalTokens` when present | Session ID; user entry ID; record timestamp | `toolCall.id/name`; `toolResult.isError/durationMs` when present | Local key shapes inspected; semantics regression uses synthetic fixtures |
| OpenCode | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| Pi-signed | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Not assumed identical to Pi |
| Grok | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| Kimi | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| Cursor | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| Gemini | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| Muse | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| Rovo | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| OMP | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | Not assumed identical to Pi |
| Agy | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |
| Devin | Unavailable | Unavailable | Unavailable | Unavailable | Unavailable | No validated reader |

All harnesses have unknown project/task/activity unless the manifest supplies those joins.
This is selected-file accounting, with explicit gaps, rather than complete all-harness accounting.
Claude's message usage follows the [Anthropic usage object](https://platform.claude.com/docs/en/api/messages/create); its cache fields are separate counters and no synthetic total is calculated.
Codex uses the [native rollout token-count structure](https://github.com/openai/codex/blob/main/codex-rs/protocol/src/protocol.rs); cache and reasoning may already be included in input/output, so the ledger never adds them to total.
Pi reads [session message entries](https://github.com/badlogic/pi-mono/blob/main/packages/coding-agent/docs/session.md) and preserves each [native usage field](https://github.com/badlogic/pi-mono/blob/main/packages/ai/src/types.ts) without synthesizing a total or changing provider-specific input/cache semantics.
These source links describe the upstream formats; live key inspection alone does not establish billing accuracy or compatibility with future revisions.

## Counting and gaps

Claude assistant fragments sharing a message ID merge field maxima, so streaming snapshots do not multiply input.
Pi entries use the original entry ID and timestamp so copied/forked history is counted once; a distinct entry counts independently even when its counters match a retry.
Codex counts monotonic differences between cumulative snapshots, ignores unchanged cumulative refreshes, and uses native last-request counters for an initial observation or a reset.
When an initial cumulative snapshot exceeds its last request, earlier usage is disclosed as unattributed rather than charged to the current turn.
On reset or compaction, last-request usage remains a lower bound and a discontinuity gap persists.
When a cumulative delta differs from the recorded last request, its observed subtotal is retained with unknown model, turn, and timestamp because the interval can span unobserved requests.
Original allowlisted provider counter snapshots remain in the local ledger; Codex cumulative raw snapshots are deliberately excluded from additive `raw_counter_totals`.
Reported reasoning and cache counters are independent dimensions, never added to input/output or to native total.

Native message/call identities prevent repeated scans, copied logs, resume, and retained fork history from multiplying counts.
Codex lacks a request ID in token-count events; its replay identity is the original timestamp plus cumulative counters, with unchanged snapshots suppressed within each source.
Independently emitted events with identical timestamps and counters can therefore collide, and retimestamped reconstructed copies cannot be proven duplicates.
Fork implementations that rewrite original entry IDs/timestamps cannot be deduplicated authoritatively.
Tool call IDs are assumed native-unique within a harness; rewritten or reused IDs make attribution uncertain.
Separate genuinely consumed retries count when the source supplies distinct IDs or advancing cumulative counters.
Unlogged failed requests, compaction's own unrecorded usage, and missing history cannot be reconstructed.

Each collection transaction commits sanitized events and offsets together.
Offsets use file identity, size, and a 256-byte checkpoint hash; inode changes, truncation, or checkpoint changes trigger a rescan with event deduplication and a durable gap.
This assumes an append-only native writer; edits earlier than the checkpoint with an unchanged tail are not detectable.
Missing files, unsupported Pi versions, malformed records, missing identities, incomplete trailing lines, and budget limits remain visible in `sources`.
An oversized line is held at its offset with a gap and requires an operator to select a suitable sanitized copy or omit that file; the collector never allocates an unbounded record buffer.
Source gaps remain visible even if a time filter excludes every event.
An empty report or a reported subtotal with unknown records is not evidence of zero usage.
All summaries declare partial coverage, including apparently complete selected files.
Updates to an existing message retain its first attribution, including unknown joins; the collector never guesses how later task labels should reassign history.
Use one consistent manifest per ledger; changes to a source's harness/labels are refused.

Tool counts represent observed native calls, with the surfaced wrapper name preserved.
A result without an observed call creates a gap instead of inventing a call.
Status and duration are unknown unless explicitly recorded.
Grouping by turn places usage beside the tools observed in that turn, but shared prompts, cached prefixes, multi-tool turns, and subprocess wrappers prevent unique per-tool billing allocation.
Payload bytes and local token estimates are currently unavailable; no estimated tokens masquerade as provider counters.
Price and per-tool token allocation are always null, and subscription usage is never treated as a marginal-dollar charge.

## Existing owners and extension boundary

[`fm-pipeline-spend.sh`](../bin/fm-pipeline-spend.sh) remains the owner of no-mistakes invocation deltas and task-purpose accounting.
Do not sum a pipeline-spend record and its native transcript usage together: they can describe the same inference.
[`fm-trace-context-lib.sh`](../bin/fm-trace-context-lib.sh) supplies identity only, and [`fm-timing-lib.sh`](../bin/fm-timing-lib.sh) supplies deferred-network elapsed times.
Neither supplies model token counts, and the collector attaches to neither surface.
There is no existing native profiling/stat counter reader in this tracked revision that supplies the requested cross-harness accounting.
Additional readers should be small explicit parser branches with native source evidence and fixtures, extending the same allowlisted event representation rather than creating a plug-in runtime or another counter service.

The summary's machine-readable output contract is [`usage-ledger.schema.json`](usage-ledger.schema.json).
`reported` is an observed subtotal and `unknown_records` counts observed usage records missing that field; wholly absent requests are expressed through source gaps, not that counter.
Tool-only groups have zero observed usage records and convey no model-usage coverage.
Keep token volume, collector wall/CPU/memory, and output quality as separate trial dimensions.
The collector measures no quality score and cannot establish that fewer tokens produced equivalent results.

## Verification

Run the portable synthetic regression through `bash bin/fm-test-run.sh tests/fm-usage-ledger.test.sh`.
It checks exact native counts, cache semantics, cumulative deltas, duplicate/copy/retry/resume/reset/rotation behavior, partial writes, unknown fields, deterministic groups, turn/tool associations, destination guards, and secret sentinels in both reports and the persistent database.
No live collection, model request, or runtime configuration change is part of that regression.
Cold scans remain linear in selected bytes; incremental scans read only appended bytes plus a bounded checkpoint per selected file.
Summary work grows with accumulated sanitized events, so long-running ledgers should be selected by trial or period rather than treated as an unbounded service.
Use a modest local measurement envelope of 5 seconds wall, 4 seconds CPU, and 96 MiB peak RSS for a fixed 6,000-request synthetic sample; report the actual sample and machine measurements privately rather than claiming those bounds hold on every machine.
