---
name: ahoy
description: >-
  Give a ten-second catch-up when the captain invokes /ahoy, asks for a morning brief, status report, catch-up, "where did I leave off", or "what is in the works".
  Detail, visual/lavish board and live/include PRs are explicit opt-ins.
user-invocable: true
metadata:
  internal: true
---

# Ahoy

Show what shipped, what is moving, what is next, and what needs the captain now.
Queue storage and commands remain separate; Ahoy is their user-facing view, so never require the captain to run a queue command.
Use current structured state for status and visible relevant conversation only for intent and continuity, deduplicating by task.
Never reconstruct hidden history after compaction or infer current decisions from report prose.
An away return first follows `/afk`; startup, locks, recovery, and supervision stay with their existing owners.

## Gather

Run `bin/fm-bearings-snapshot.sh --json --record-look` once for a fresh bounded snapshot.
Its header and `--help` own fields, bounds, and expansion flags.
Do not create a second fleet reader, reinterpret raw status tails, probe projects, or run ad-hoc forge discovery.
Default mode uses local/cached records without a live PR sweep.
Pass `--include-prs` only for explicit `live` or `include PRs` requests.
For `detail`, reveal only the snapshot surfaces needed by the request.
For explicit `lavish` or `visual` mode, load `ahoy-board`; ordinary chat creates no report or board.
File-report mode and the `/bearings` alias are retired.
Do not read or write old status-report files.

## Chat contract

Lead with a short "Since your last look" signal from `since_last_look` when there is a previous checkpoint.
Call these newly visible deliveries or changed stages, not exact-time event history; the checkpoint compares observed durable facts within the snapshot bounds.
Report disappeared current rows as no longer observed, never as proof of completion.
Say briefly when there are no observed changes, then always give the current picture below.
On the first look or an unreadable checkpoint, disclose that there is no earlier comparison rather than inventing a catch-up.
The command saves only one compact checkpoint, never a report archive.

Aim for a ten-second glance, one line per item, with complete task titles and full artifact URLs.
Omit empty section headings and all empty-state filler, including unheaded "Nothing needs you right now" after completion.
Use these sections in order only when they have qualifying items:

- **Shipped**: real recorded merges, local-main landings, and completed scout reports from `landed`.
  Include each row's artifact: the full PR URL, `local main`, or the scout report link.
  Closing or folding a queue item is not shipping.
- **Moving**: one line per `in_flight` row with its full `name`, plain `stage`, and elapsed time from `elapsed_seconds`.
  Round elapsed time to minutes or hours; null means timing unavailable, not zero.
  Keep blocked, paused, failed, or unknown state explicit; do not invent progress percentages or ETAs.
- **Next**: the useful queued work from `gates`, in snapshot order, with any actual blocker or date.
  Collapse deferred captain holds to at most one short note, naming the revisit condition or date; do not repeat their questions.
  Keep inventory warnings visible without presenting them as dispatchable work.
- **Needs you**: only non-deferred `decisions_open`, a confirmed PR-ready merge choice, credentials, or blockers requiring the captain now.
  Include actionable `contributions.captain` rows, deduplicated against existing calls.
  Do not print contribution counts, checked/known coverage statistics, or action-free contribution rows.

A hold with a recorded revisit condition, future date, or unresolved blocker stays deferred even in detail mode.
The canonical snapshot's structured hold classification owns that distinction; never guess from hold-reason prose.
An elapsed date does not authorize dispatch or close a decision.
A recorded PR URL alone does not prove merge readiness.
Put publication or CI uncertainty on the affected work row or in a short unheaded note; it alone creates no captain action.
Completed scout reports, active validation, and declared external waits never become captain calls merely because they exist.
If required state is unreadable, say so briefly instead of claiming all clear; leave detailed omissions behind `detail`.
Include the required captain address naturally once.
Keep detailed plans, options, evidence, usage accounting, and operational ids out of the glance unless essential to the requested decision.

## Authority

A catch-up changes only its observation checkpoint: never dispatch, steer, merge, answer a call, change queue state, or clean up during it.
Name any needed action and leave execution to the normal lifecycle.
Only explicit board mode writes its board, binding, and source registration; its later answer wake follows `ahoy-board`.
