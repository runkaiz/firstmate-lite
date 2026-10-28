# Same-run behavior assessment

Assessed head: `c63e3c1287cb6a3c337ffe31b0acedb11244a239`.
Run: `01M5Z7HH87MVR9K988M9MEHRVD`.
Verdict: **go**, based on independently verified observations below and retained focused regressions.
This was read-only evidence reassessment; no scenario, model, lifecycle, test suite, pipeline operation or source edit was performed again.

## Exact current-head product behavior

Actual supervisor commands and results were matched to the hash-bound original session, not inferred from the prompt:

1. `fm-control.sh historical-6 exit` refused an ambiguous endpoint. `fm-tasks-axi.sh show delivery --full` found the existing queued delivery.
2. `fm-lease.sh claim delivery` and `claim backlog` preceded `fm-captain-hold.sh hold delivery --reason ...`; `open delivery` returned zero before the report. The backlog contains the held delivery and no surrogate producer task.
3. `fm-branch-report.sh --task repair --verdict captain ...` recorded one escalation. The first host turn recorded `rc=0 reports=1 error=0`.
4. `fm-wake-drain.sh --ack-through 32 --recovery-generation <actual-generation>` consumed the actual first grant. Hash-bound owner and turn records grant rows 1-32; the recorded queue became empty before the follow-up.
5. On the one unchanged follow-up, `fm-captain-hold.sh open delivery` again returned zero; `fm-branch-report.sh --task repair --verdict routine --silent true ...` recorded the sole second outcome. The second actual acknowledgement consumed rows 33-34, with a second `rc=0 reports=1 error=0` host receipt and empty queue.
6. Final admission still refused sixteen occupied or unconfirmed records at cap four. All fifty preserved hashes match the retained home and both complete archives. Original cleanup completed at 52.383148 seconds with no cleanup errors. The subsequent recorded absence audit identifies thirty owned processes absent and the private socket absent; it is not a new probe during this reassessment.

The original harness remains **NO-GO / exit 1**: `NameError: inventory is not defined` occurred in final result assembly after the two-turn, hold, preservation, admission, cap, prompt and head assertions. Nothing rewrites that result or claims the entire harness passed.
Original result SHA-256: `34e64427b454892ab12e1581bf1c1e1ea082534bcd428180ccbe45b1e1be475b`.

## Earlier positive execution and continuity

The actual positive execution belongs to this same run at `05fc1a8d67a702f8ac7ab19aa6fa776ba9d55863`, not to a replay at the current head.
The original supervisor inspected retained context, used guarded exits for twelve safely bound idle endpoints, encountered genuine capacity refusals until sufficient capacity was released, then successfully relaunched the existing delivery with its dirty copy preserved.
Twelve archived stop receipts, a complete relaunch journal, matching fresh generation/transaction metadata, and the eventual worker receipt establish concrete progress under cap four.
The idle endpoints were real private shells with truthful legacy bindings, not sixteen prior model launches.
All sixty-five preservation hashes match the retained files and all three archives.

The original attempt remains **NO-GO** at 48.432556 seconds: pending granted rows and a cleanup refusal while the worker composer held text.
The matching processed-worker receipt arrived **after** that NO-GO.
Supported supplemental cleanup finished at 97.282665 seconds; the later recorded absence audit found sixty owned processes and the private socket absent.
Those later observations do not move before or replace the failed original result.
Original result SHA-256: `19f2873fe16e53e9ffb2416fa16195c9c79cc18fa49b6b3cfa71047e5c55a23b`.

Only `bin/fm-branch-prompt.sh` and its regression test differ between the positive head and the current head.
The delta resolves the fallback delivery identity and forbids surrogate producer tasks; the positive reclamation rule and capacity, exit, relaunch, project admission, hold, lease and host mechanisms are unchanged.
Thus the earlier observed progress supports current behavior by continuity, while the current exact-head negative execution directly exercises the corrected decision.
This is sufficient for the accepted progress-or-genuine-blocker criterion; it does not promise model obedience for every possible prompt or claim completed publication.

## Remaining coverage and limits

The same-run real away-record CLI transcript at `072a4c7` shows an unspecified cap as `-`, explicit four preserved across replacement words, explicit revision to two, and rejection of zero without mutation. The away-record implementation is byte-identical at the assessed head. Legacy finite-record preservation also has retained deterministic regression coverage.
The retained focused afk-contract, control, relaunch, branch-supervision and project-capacity checks cover preservation and admission guards. The exact-head producer/delivery regression passed previously; it supplies the identity explicitly and is not model-decision evidence.

Exact absent-Herdr release has **no live backend execution** in the retained evidence. Its provider-backed regression reproduced failure before the correction, passed afterward, and exercised live/unknown/stale/foreign/stopped-server refusal boundaries. This remains an untested live scenario, not a fabricated live pass. No real Herdr lifecycle is authorized for this reassessment. The bounded deterministic guard evidence plus actual unknown-owner refusal is sufficient supporting coverage here; this limitation does not negate the independently demonstrated accepted handoff behavior.

The installed-build source archive and cited source hashes were independently verified. The validator rejects pass/live=false; its correction-only prompt cannot reopen underlying evidence. Live labels here describe verified real executions in this run, not this review's file reads.
Raw private paths, session identifiers and transcripts remain private. The paired JSON artifact contains sanitized integrity results. Existing evidence and all original failures remain unchanged. Remaining pipeline stages still own their required checks.
