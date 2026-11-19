# Proactive orchestration policy (active only while the preference is on)

Continue approved work through routine handoffs and already-approved next steps without a fresh permission question or a phase-by-phase chat report.
New no-mistakes briefs generated while on use the worker's immediate validation handoff owned by `bin/fm-dod-lib.sh`, removing the implementation-done/firstmate-invocation round trip.
Within that accepted task, an unambiguous bounded reversible defect repair is authorized by this mode: have the responsible worker fix it without asking whether it should be fixed.
Approved landing includes wrap-up: carry worker, tab and copy retirement through, including [ship-landing](../ship-landing/SKILL.md)'s guarded preservation of task-owned generated leftovers, until cleanup succeeds or a genuine refusal needs the captain.
Firstmate still delegates project changes, and an implementation worker still routes validation ask-user findings to firstmate under [ask-user-authority](../ask-user-authority/SKILL.md).
That policy remains the authority for deciding findings; do not forward an unambiguous in-scope finding merely because the gate calls it ask-user.

Reuse the current startup digest, presented wake records, and completed validation evidence instead of repeating their preflights at each handoff.
Read again when evidence is missing, stale, contradictory, or the next action's owning guard requires a fresh check.
Keep focused validation of affected behavior, the selected delivery pipeline, real required checks, truthful failures, and useful outcome reports.
Skip routine phase chatter and duplicate no-change reports; surface meaningful results and failures.
Record discovered work that cannot fit the current bounded task through the existing [work queue](../work-queue/SKILL.md), preserving its authority and eligibility instead of treating discovery as authorization to dispatch it.

Decide a call yourself when you hold a confident recommendation that stays inside the captain's accepted direction and is reversible: act on it (land, dispatch the next queued step, pick the recommended option) and report the outcome with its reason in one line instead of presenting options.
Escalate only a genuine direction change, product ambiguity the accepted direction does not settle, or material scope expansion, with the smallest useful choice while independent approved work continues.
Honor explicit stops, holds, declined or deferred work, and task boundaries immediately; proactive mode never releases a captain hold.
It authorizes no unrelated project, open-ended improvement, new publication scope, credential/private-data access, destructive, irreversible, or security-sensitive action beyond existing explicit authority.
Preserve GPU/resource spending grants, unlanded-work protection, leases, isolation, capacity, and the existing supervision owner.
Read-only or lock-refused sessions remain read-only.
Never toggle yolo, waive validation, or take over a worker-owned pipeline.

ON supplies recorded standing approval under [ship-landing](../ship-landing/SKILL.md) for authorized in-scope ordinary GitHub PR merges and local-only landings even with project yolo off.
Treat this as standing approval in that owner's existing authority order, never as a parallel override.
Land only after validation for the exact current head passes, required PR checks and reviews pass where applicable, and findings are resolved.
Use `bin/fm-pr-merge.sh <task-id> <pr-url> --proactive` or `bin/fm-merge-local.sh <task-id> --proactive`; their headers own action-time preference and landing guards.
When this `--proactive` landing path is available, use it rather than asking for landing approval; never ask solely because yolo is off.
Explicit review-first or do-not-merge instructions, explicit task restrictions, captain holds, failed or missing validation, and destructive, irreversible, or security-sensitive exceptions still require the captain.
Check accepted scope and unresolved findings before using this authority, keep publication within existing consent, and report the actual full-URL or local landing outcome.
OFF withdraws this additional authority immediately for subsequent actions; baseline explicit or yolo authority remains separate.
Non-GitHub PR merges retain their baseline authority.

The supervision branch applies this policy only inside its existing role and posture authority.
For a handoff or decision reserved to MAIN, report it once so MAIN can continue; `bin/fm-branch-prompt.sh` "Attended routine outcomes" owns the attended exceptions.
`bin/fm-branch-prompt.sh` "Postures" owns continuing authority and additional away instructions; proactive mode never wakes parked MAIN.
