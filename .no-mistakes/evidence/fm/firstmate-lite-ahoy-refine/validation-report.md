# Ahoy live validation: no-go

Target: `a79049dc9e2db6d6bf4dabc68ee8b5f9fe55657d`.

The snapshot regressions and the focused conditional-hold regression pass. Real Claude evaluations pass for ordinary quiet, 71 cached action-free contributions, three unreadable-record replies, deferred holds, full titles, real worker progress, and completion with unverified PR readiness. A native mixed catch-up still violates the accepted presentation contract and mislabels an existing queue item as new.

## Failure: mixed catch-up

Public native entry point: `/ahoy`, with the installed project skill, real authenticated Claude, and `bin/fm-bearings-snapshot.sh --json --record-look`. Each primary ran on the disposable home's private `fm-lab` tmux socket at 120 by 40; project hooks were disabled to isolate this read-only catch-up.

The before checkpoint was generated at `2026-11-10T22:55:48Z`. `Publish the importer guide` was already queued and blocked by `delivered`. The next snapshot changed only that row's blocker to `-`; it did not create the queue item. `Repair the importer retry logic` acquired a recorded merge artifact. An unrelated moving row disappeared without a delivery artifact.

Before:
```json
{
  "id": "followup",
  "title": "Publish the importer guide",
  "blocked_by": "delivered",
  "reason": "-",
  "deferred": false,
  "owner": "(main)",
  "filed": "2026-11-10"
}
```
After:
```json
{
  "id": "followup",
  "title": "Publish the importer guide",
  "blocked_by": "-",
  "reason": "-",
  "deferred": false,
  "owner": "(main)",
  "filed": "2026-11-10"
}
```
Actual native reply:

Captain, here's what changed since your last look: one fix shipped, one new item is queued, and two earlier items no longer appear in the records.

**Shipped**
- Repair the importer retry logic: https://github.com/ahoy-lab/example/pull/3

**Next**
- Publish the importer guide: nothing is blocking it.

"Investigate the previous import route" no longer shows as in progress, and "Repair the importer retry logic" is no longer queued now that it shipped. Neither disappearance proves the investigation finished. Nothing is in progress right now and nothing needs a decision from you.

This view uses local records only, without a live PR check. There is one outside contribution on record, which is mine to handle, and its status hasn't been checked yet.


This reply incorrectly says “one new item is queued.” It also adds the forbidden empty inventories “Nothing is in progress right now and nothing needs a decision from you” and the action-free contribution count “one outside contribution on record.” There were no decisions or actionable contribution rows. Its disappearance caveat and shipped artifact are correct.

An earlier independent native evaluation of the same transition also called the existing task newly queued:

Captain, here's what changed since your last look:
- **Repair the importer retry logic** is newly shipped.
- **Publish the importer guide** is newly queued.
- **Investigate the previous import route** no longer shows up as active work. That doesn't confirm it finished.

**Shipped**
- Repair the importer retry logic: https://github.com/ahoy-lab/example/pull/3

**Next**
- Publish the importer guide: nothing is blocking it.


The generated comparison emits current values for both new and changed rows without distinguishing those transitions. The blocker change itself is preserved correctly, but the chat surface twice described it as a newly queued task. Keep the compact checkpoint while giving the consumer enough change information to describe the transition honestly.

## Passing product evidence

Quiet with 71 cached, checked, action-free contributions:

No observed changes since your last look.

Captain, all quiet in the local records.


Unreadable contribution record (third of three evaluations; all omitted empty inventories):

No observed changes since your last look.

Captain, this update may be incomplete: one contribution record could not be read.


Native `/ahoy` while a real Claude worker was processing:

Captain, no observed changes since your last look.

**Moving**
- Implement the approved import workflow while preserving the full task title across the Ahoy glance: implementing, under a minute elapsed. A PR is on record at https://github.com/ahoy-lab/example/pull/2, but I didn't check it live, so its checks and merge readiness are unconfirmed.


Native `/ahoy` after that worker finished:

Captain, no observed changes since your last look.

**Moving**
- Implement the approved import workflow while preserving the full task title across the Ahoy glance: implementation finished, under a minute elapsed. A PR is recorded at https://github.com/ahoy-lab/example/pull/2, but whether it published and passed CI hasn't been checked, so it isn't confirmed ready to merge yet.

This catch-up used local records only and didn't check live PRs or contribution status. Ask for "/ahoy include PRs" to check them live.


The executable also excluded folded and artifact-free closures from shipped, kept conditional and future-dated calls deferred under detail expansion, rejected a hold combining a date and condition without changing the queue, observed an answered call and removed queued row as no longer observed, detected cleared blockers, recovered a corrupt checkpoint, kept one compact checkpoint, and left queue bytes unchanged during every checked catch-up.

## Commands and isolation

- `TMPDIR="$PWD/.ahoy-validation/tmp" bash tests/fm-bearings-snapshot.test.sh` initially inherited the enclosing worktree's Git origin through empty fixture directories, so a repository-cap assertion saw six repositories instead of five.
- `TMPDIR="$PWD/.ahoy-validation/tmp" GIT_CEILING_DIRECTORIES="$PWD/.ahoy-validation/tmp" bash tests/fm-bearings-snapshot.test.sh` passed after isolating Git discovery.
- `FM_QUEUE_TEST_ROOT="$PWD/.ahoy-validation/tmp" python3 tests/fm-queue.test.py QueueTests.test_conditional_captain_hold_round_trip_and_release -v` passed.
- `python3 .ahoy-validation/live.py` drove the snapshot, queue, hold, and real-Claude chat scenarios. Archived as `live-ahoy-driver.py`.
- `python3 .ahoy-validation/progress.py` drove the real worker and native skill scenarios. Archived as `real-worker-driver.py`. The first native attempt disabled project settings and therefore skill discovery; enabling project sources registered `ahoy` in the real CLI consumer and both final native evaluations passed.
- `python3 .ahoy-validation/catchup.py` drove two native mixed catch-ups. Archived as `away-catchup-driver.py`. The first driver's assertion expected an internal id instead of the emitted full task title; this assertion was corrected, and the rerun passed mechanical snapshot assertions while retaining the chat failures above.

No complete repository suite, lint, format, static analysis, pipeline control, forge mutation, or external lifecycle was run. Disposable homes, Git repositories, and sockets stayed inside the worktree and were removed. No product files were changed. The outputs are CLI/chat text; no GUI renderer or layout was exercised, so there is no screenshot.

`live-away-before.json`, `live-away-after.json`, and `native-ahoy-away-stream.jsonl` form the matching final before/after/chat evidence. Files named `live-away-before-first.json` and `live-away-cli-first.log` are copies captured after the second invocation started; do not use those as the first invocation's temporal baseline. `native-ahoy-away-first.md` preserves the first actual reply.
