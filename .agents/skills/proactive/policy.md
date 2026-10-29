# Proactive orchestration policy (active only while the preference is on)

Continue approved work through routine handoffs and already-approved next steps without a fresh permission question or a phase-by-phase chat report.
New no-mistakes briefs generated while on use the worker's immediate validation handoff owned by `bin/fm-dod-lib.sh`, removing the implementation-done/firstmate-invocation round trip.
Within that accepted task, an unambiguous bounded reversible defect repair is authorized by this mode: have the responsible worker fix it without asking whether it should be fixed.
Firstmate still delegates project changes, and an implementation worker still routes validation ask-user findings to firstmate under [ask-user-authority](../ask-user-authority/SKILL.md).
That policy remains the authority for deciding findings; do not forward an unambiguous in-scope finding merely because the gate calls it ask-user.

Reuse the current startup digest, presented wake records, and completed validation evidence instead of repeating their preflights at each handoff.
Read again when evidence is missing, stale, contradictory, or the next action's owning guard requires a fresh check.
Keep focused validation of affected behavior, the selected delivery pipeline, real required checks, truthful failures, and useful outcome reports.
Skip routine phase chatter and duplicate no-change reports; surface meaningful results and failures.
Record discovered work that cannot fit the current bounded task through the existing [work queue](../work-queue/SKILL.md), preserving its authority and eligibility instead of treating discovery as authorization to dispatch it.

Escalate genuine product ambiguity or material scope expansion with the smallest useful choice while independent approved work continues.
Honor explicit stops, holds, declined or deferred work, and task boundaries immediately; proactive mode never releases a captain hold.
It authorizes no unrelated project, open-ended improvement, new publication scope, credential/private-data access, destructive, irreversible, or security-sensitive action beyond existing explicit authority.
Preserve GPU/resource spending grants, unlanded-work protection, leases, isolation, capacity, and the existing supervision owner.
Read-only or lock-refused sessions remain read-only.
Never toggle yolo, waive validation, or take over a worker-owned pipeline.

For MAIN firstmate, ON grants automatic merge authority for an authorized in-scope ordinary GitHub PR even with project yolo off, once current-head required checks and reviews pass and findings are resolved.
Use `bin/fm-pr-merge.sh <task-id> <pr-url> --proactive`; its header owns the action-time preference, synchronous-merge and review guards.
Do not ask for another merge approval solely because yolo is off.
Explicit review-first or do-not-merge instructions, captain holds, and destructive, irreversible, or security-sensitive exceptions still require the captain.
Check accepted scope and unresolved findings before using this authority, keep publication within existing consent, and report the actual full-URL outcome.
OFF withdraws this additional authority immediately for subsequent actions; baseline explicit or yolo authority remains separate.
Local-only landing and non-GitHub merges retain their baseline authority.

The supervision branch applies this policy only inside its existing role and posture authority.
For a handoff or decision reserved to MAIN, report it once so MAIN can continue; this mode gives an attended branch no new spawn, merge, or decision-answer authority.
Away instructions remain the whole away mandate; proactive mode does not enlarge it or wake parked MAIN.
