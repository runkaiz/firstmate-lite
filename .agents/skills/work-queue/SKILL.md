---
name: work-queue
description: >-
  Load before capturing or revising work/outcome intent, selecting queued work,
  and reconsidering eligibility at startup, heartbeat, completion/teardown,
  or a capacity-bound PR-ready handoff. Uses the native queue and existing lifecycle owners.
user-invocable: false
metadata:
  internal: true
---

# Work queue

Use `bin/fm-queue.sh` as the single authority for task and outcome records.
Its current help and the shipped storage interface own syntax; [Native work queue](../../../docs/queue.md) owns supported behavior and compatibility/activation limits.
The old `fm-tasks-axi.sh` spelling is a native alias, never a reason to run or install external tasks-axi.

Resolve the project and inspect matching records before creating work.
Read the selected record with `show <id> --full`, including archived records, rather than loading every body/report.
Preserve accepted intent, its authorization source/scope, and the next useful step or evidence in that body.
Keep priority, actual dependencies, hold conditions and artifact links in their existing structured fields.
Use `update|edit` for follow-ups on the same ID; native storage archives the previous body automatically.
For executing work, also append actual new intent to its brief and steer through the current `fm-send` inbox path.

Capture an idea with `add <id> <title> --idea`; this atomically creates indefinite parked context, not an unanswered human decision.
Only an actual accepted instruction authorizes it: use `authorize <id> --body-file <intent>` to preserve that instruction and release the idea hold.
Neither time, priority, readiness nor roadmap membership grants authority.
Capture already-authorized upcoming work as an ordinary queued task under existing intake; do not impose another planning approval.
Reconcile legacy work against available accepted-intent evidence instead of blanket reapproval.

For a real multi-task outcome, use `add <id> <title> --outcome` and put purpose and constituent IDs in its body.
The outcome is non-executing context, not a second writable roadmap list.
Membership never implies dependency or permission; use dependencies only for genuine prerequisites.
A small task needs no umbrella, and a broad outcome needs no speculative subtask inventory.
Use the existing human hold/answer owner on the actual task for a genuine choice; never substitute idea authorization for its recorded answer.

At startup, reconcile the one digest's recovery facts before selection.
At heartbeat, completion/teardown and a capacity-bound PR-ready handoff, obtain `ready` candidates and the existing bounded fleet snapshot in the current supervision turn.
Inspect bodies only for selected or reconciled work, and retain existing priority and tie ordering.
Check accepted scope and existing metadata/status/inbox ownership before dispatch; readiness is not evidence that no worker owns the ID.
Recover an interrupted worker/queue transition through bootstrap/current-state owners under that same stable ID instead of duplicating dispatch.
Use normal brief, dispatch-profile and spawn paths with the selected delivery mode.
Capacity exit 75 keeps work queued; retain its refusal context and reconsider at the next existing relevant opportunity.

Use `fm-crew-state.sh` and the existing lifecycle evidence to distinguish running, paused, blocked and retained-dead workers.
Endpoint death never proves completion.
Only the delivery/teardown owner closes real work and records artifacts; a human-answer release and task completion remain distinct.
After real prerequisite completion, reconsider ready work so its dependent needs no reminder.
Add no scheduler, timer, daemon, mandatory board or second queue.
