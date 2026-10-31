---
name: ship-landing
description: Load when a ship reports a PR or ready branch, when deciding or monitoring landing, and before task cleanup.
user-invocable: false
metadata:
  internal: true
---

# Ship landing

After completion/teardown or a capacity-bound PR-ready handoff, use `work-queue` to reconsider eligible work through the native queue and existing intake path.

For PR-based ship tasks, the ready signal depends on mode: `no-mistakes` reports `done [at=<epoch>]: PR <url> checks green` after CI is green, while `direct-PR` reports `done [at=<epoch>]: PR <url>` after opening the PR, each only for a non-draft PR; a lane that deliberately holds a draft declares a wait instead, and `bin/fm-pr-check.sh` refuses to arm merge monitoring on a draft.
If a delegated CI wait remains registered, follow [`validation-supervision`](../validation-supervision/SKILL.md) before arming merge monitoring.
Run `bin/fm-pr-check.sh <id> <PR url>` with the URL copied from that ready signal or the resolved checks-green `fm-crew-state.sh` line - it records `pr=` and the forge's `pr_head=` when available in the task's meta and arms the watcher's merge poll.
`bin/fm-dod-lib.sh` owns the named-head gate on that ready signal: a ship `done:` whose named head exists only in the worker's disposable copy is not ready (`bin/fm-crew-state.sh` reports blocked, `bin/fm-pr-check.sh` refuses to register, and a secondmate does not publish that done upstream).
That blocked reading is the gate working, not a stuck worker, so steer the worker on the commit the refusal names rather than waiting.
A direct-PR worker pushes that commit to its PR branch, and a local-only worker commits it on its ship branch.
A no-mistakes worker re-validates it with /no-mistakes so the pipeline stays the one publisher; it never pushes from its copy.
When the generated no-mistakes handoff calls for an implementation-only `done [at=<epoch>]: {summary}`, that signal is not gated; `bin/fm-dod-lib.sh` owns when this handoff is used.
Tell the captain the PR's full `https://...` URL copied from the worker's ready line, the resolved checks-green crew-state line, or the task's `pr=` metadata, a concise outcome summary, and the no-mistakes risk level when applicable.
A captain instruction to merge is explicit authority; standing routine merge authority comes from `yolo` or the active [proactive policy](../proactive/policy.md).
For any custom `state/<id>.check.sh` you write yourself, keep it an ordinary single-link mode-`0700` file, print one line only when firstmate should wake, print nothing otherwise, finish before `FM_CHECK_TIMEOUT`, then bind its current bytes with `bin/fm-check-register.sh <id>` before the watcher may execute it.
Retire a custom check only through `bin/fm-check-unregister.sh <id>` (or `bin/fm-teardown.sh` for a spawned task); never hand-compose an `rm` with `$STATE`/`$ID`.

Tear down a ship task only after landing is confirmed.
A teardown refusal for uncommitted or unlanded work is a stop-and-investigate result, never an obstacle to bypass.
When a native copy refuses only for untracked or ignored leftovers, inspect each listed path read-only; if every one is a task-owned generated artifact (build output, bytecode, a tool or dependency cache the task created) and nothing else blocks, the next action is the same teardown with `--preserve-untracked <path>` per leftover, whose script header owns the move, custody check and resume.
Ignored status alone never proves an artifact disposable: tracked edits, unlanded commits, anything that could be unique work or session evidence, and uncertain ownership stay stop-and-escalate.
With proactive mode on, take that preservation as part of the approved wrap-up without asking; with it off, report the classification and the exact command as the proposed next action.
Never force teardown without explicit discard authority.
After successful teardown, record completion, retain only the configured recent Done history, and re-evaluate queued work whose blockers and time gates have cleared.
Treat the recorded worker, tab and disposable copy as one wrap-up through `bin/fm-teardown.sh`; an endpoint-only control exit is not task cleanup.
If cleanup refuses or is interrupted, retain the task with the exact unresolved resource, refusal evidence and next safe action instead of marking wrap-up complete or repeatedly announcing unchanged idle workers.
Write that next action, including any preservation command, into the backlog item note: the retained task record and In-flight item are what a restarted session reconciles, and it resumes the action from the note rather than re-asking.

A secondmate is persistent and an empty queue is healthy.
Retire one only on an explicit captain or main-firstmate decision, after loading `secondmate-provisioning`; its home must contain no work under way, and forced discard still requires explicit captain authority.
