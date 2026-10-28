# Native work queue

Firstmate-lite ships its queue backend in `bin/fm-queue.py`, using Python 3.9+ and its standard library.
External tasks-axi is not a runtime dependency.
Use the home-addressed `bin/fm-queue.sh`; `bin/fm-tasks-axi.sh` remains a compatibility entry point to the same backend.
The storage executable's header and help own exact command and file mechanics.

## One authority and preserved identity

The native queue retains the existing Markdown task representation, configured active file, completed-task archive and note history.
The archive and note history are parts of that queue, not independent writable planning lists.
Normal reads, identity checks and mutations share locking; multi-file writes have a recoverable transaction so interruption does not silently lose a task.
Malformed records, duplicate identities, conflicting recovery data and unsupported adapters fail with a diagnostic before a new mutation is committed.

`show` finds active and archived tasks by original ID.
`reopen` moves an archived task back to the active queue with its original identity, body, hold provenance and artifact links.
Creation refuses identities found in either active storage or the archive, including conflicts between them.
Replacing a body automatically archives the superseded record in the existing note history.
`rm` archives only already-complete work and retains its identity; unfinished work stays in the queue and can be parked without implying that its dependents are unblocked.

## Capture and pickup

An ordinary queued task represents accepted work whose scope is retained in its body.
`add --idea` atomically parks an idea indefinitely; `authorize` requires the accepted instruction before making that same record executable.
An outcome created with `add --outcome` is indefinitely parked context linking existing task IDs, not an executable parent job.
Neither an outcome link, a priority nor time passing authorizes an idea or creates a dependency.
Small work needs no umbrella.

Readiness uses existing priority, actual dependencies and hold fields, including completed prerequisites in the archive.
Fleet projections use a locked native observation of the active text and completed identities so archived prerequisites do not appear blocked in one view and ready in another.
The existing intake and supervision paths reconsider candidates at startup, heartbeat, completion/teardown and relevant capacity-bound handoffs; there is no queue scheduler or new daemon.
Existing dispatch/completion owners still pair queue state with real worker metadata and evidence.
Worker exit alone never closes a task, and capacity refusal leaves it queued.
Real human choices continue through `fm-captain-hold.sh`, preserving the actual answer and the distinction between releasing work and completing it.
A captain hold's date controls deferral, not authorization: it remains held until answered/released, while an ordinary authorized time gate can expire normally.
The away-return human-decision group excludes parked context using the hold-kind field.

## Existing homes and reversibility

Compatibility does not authorize activation or a live-home rewrite.
The current operating backend remains authoritative until an operator explicitly chooses to activate the validated native replacement.
Never run native and external writers concurrently against the same files: their lock protocols differ.

With writers stopped, run the native `migrate --dry-run` compatibility check on the explicitly selected home.
The supported Markdown format requires no rewrite.
Use `migrate --backup-dir <new-directory>` to save byte-for-byte copies of existing active, archive and note files plus their hashes before an approved activation.
The backup refuses an existing destination and does not switch configuration, install a CLI, start a home or import data into another store.
If rollback is necessary, stop native writers first and restore those original files and the original backend/configuration from the preserved backup under the operator's authority.
Keep any subsequent native work separately preserved before restoring an older snapshot.

The existing `.tasks.toml` Markdown paths and retention are accepted as compatibility configuration.
Backend selection checks the explicit CLI option, `FM_QUEUE_BACKEND`, `TASKS_AXI_BACKEND`, the owning root's `.tasks.toml`, then legacy `~/.tasks-axi/config.toml`, in that order.
Only the effective legacy backend selection is inspected; user-level paths and other settings are not imported.
An unreadable or malformed effective selection refuses access before queue reads or writes.
Legacy non-Markdown adapters are refused rather than silently migrated or kept behind the native wrapper; their export/activation needs a separately approved compatible path.
Synthetic compatibility, identity, concurrency and crash-recovery checks run through `bash tests/fm-queue.test.sh`; they do not claim live agent execution or home activation.
