# Focused verified-absence correction

Test-phase fix only. Overall required live validation remains INCONCLUSIVE.
Parent HEAD: 072a4c788d97fca34e96a5c04c0b27579467a574.
Source and test changes are uncommitted for the outer executor; this parent HEAD does not identify the changed working tree.
Working patch SHA-256: 6285c333239eb4cc08f1debb9546d94a3fff70a4dedb358346cfa1954a1705de.
No new commit, pipeline control, model experiment, real Herdr lifecycle, lint, formatter, or full-suite run was performed.

## Reproduction and correction

The regression failed before the source change with `verified gone worker retained its slot` and an AFK cap-one refusal after the real exit CLI wrote a generation-matching stop receipt.
The same receipt passed admission when only the canned pane response changed to a visible agent-free endpoint.
The initiating trigger was verified exit of the exact absent Herdr pane; the divergence was its generic `missing` state versus the accepted `dead` state of a visible agent-free endpoint.
Admission now combines the existing matching receipt and endpoint ownership validation with the adapter's fresh read-only exact pane-absence proof.
Generic missing, stopped-server, unknown, live, stale, foreign, and inconsistent identity evidence remains charged.
No server is started by counting, no record is removed, and unmerged copies survive.
The regression also verifies replacement launch through the canned provider and reacquisition of the slot.
The copied-holder fixture now rewrites only endpoint identity fields, keeping its real project/worktree paths.
The 16-record test now distinguishes ten owner-parked historical records from six remaining holders before parking three staged contexts under the same cap four.
Fresh admission probes deliberately stop at project validation; they are not evidence of a completed delivery.

## Focused verification

Command: `timeout 360 bash bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 170 tests/fm-control.test.sh tests/fm-control-relaunch.test.sh` with a disposable worktree-local TMPDIR.
Runner exit: 0.
The scripted provider fixtures are deterministic behavior evidence, not model obedience or live-provider evidence.

```text
ok - AFK: completion/PR/holds do not imply stopped; confirmed stop frees capacity and preserves evidence
ok - AFK: late agents, unknown/missing/unsupported liveness and stale receipts retain occupancy
ok - AFK: typed/raw/explicit-endpoint steering cannot reactivate stopped worker; inbox evidence survives
ok - AFK: confirmed stopped AI worker releases its slot while unrelated background work remains running
ok - AFK: nine retained worker records release four-cap admission after verified stops without deleting evidence
ok - AFK: staged contexts plus historical records reproduce refusal; supported parking admits delivery without cleanup; unknown ownership still blocks
FM_TEST_END 2026-10-27T18:16:59Z tests/fm-control.test.sh exit=0 duration_ms=34574 gate_skip=false
ok - AFK: owner-verified exact Herdr absence releases capacity without deleting preserved work
ok - AFK: stopped-worker relaunch reacquires capacity and replacement boot retains its reservation
ok - AFK: concurrent admission cannot pass a relaunch while its provider is still starting
FM_TEST_END 2026-10-27T18:17:49Z tests/fm-control-relaunch.test.sh exit=0 duration_ms=50001 gate_skip=false
FM_TEST_SUMMARY total=2 failed=0 skipped_gate=0 duration_ms=84610
FM_TEST_SUMMARY_FAMILY family=backend-dispatch count=2 duration_ms=84575 failed=0
```

The relaunch script's existing cleanup emitted permission warnings for read-only temporary hook directories despite its successful assertions and exit zero.
The worktree-local disposable fixture tree and raw test log were separately removed after making only that tree user-writable.
An earlier focused invocation used the default temporary directory and reported the same cleanup warnings; no out-of-worktree cleanup mutation was attempted.
No transient test artifacts are intended for commits; dependencies were not removed.

## Retained external observation and residual gate

The immutable original runner receipt's hash matches its execution receipt, and both name the same run and parent HEAD above.
The original runner remains exit 1 / NO-GO at 57.477449836966116 seconds including immediate cleanup.
It observed two host-handled turns, a durable delivery hold, one escalation, a silent unchanged follow-up, genuine host acknowledgements, zero changed selected fixture files, and cap four.
Immediate cleanup failed; the fixture archive and retained fixture were preserved.
Supplemental read-only evidence reports all recorded processes later absent, but elapsed start-to-supplemental-absence is UNKNOWN because no exact start wall timestamp exists.
Later absence does not rewrite the original NO-GO.
No positive live parking/relaunch or delivery progress is proven by that negative ownership-blocker observation.
The source correction makes the retained observation inapplicable as current-head live validation.
Minimum next action: the outer executor must retain the residual Test gate and obtain MAIN's explicit rebind and validation direction for its resulting full commit SHA, including the remaining positive reclamation/progress and cleanup evidence.
No replay, waiver, skip, approval-over-failure, or new experiment is authorized by this report.
Raw private evidence was read only; no raw transcript, process identifier, private source path, archive, or scenario script was copied into publishable evidence.
