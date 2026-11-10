# Targeted Ahoy test-phase fix

2026-11-10. Source head a79049dc9e2db6d6bf4dabc68ee8b5f9fe55657d plus local fixes.

## Reproduction and cause

The archived away-catchup driver was run unchanged except for redirecting its evidence into the worktree.
Native Claude /ahoy replied “New in the queue: Publish the importer guide” for an existing queued item whose delivery blocker cleared.
The executable comparison contained only the current value, losing the distinction between a newly observed item and a changed existing item.
The strengthened executable regression failed before the fix, then passed with previous values included in the public comparison.
The on-disk checkpoint schema and rows remain unchanged and compact.
The reported filler also has prior live evidence in ../native-ahoy-away.md; it did not recur in this turn's initial reproduction.
Ahoy's chat contract now applies empty-inventory and contribution-count omission to the entire mixed reply, including the comparison and closing prose.

## Verification run

- `python3 .ahoy-validation/catchup.py` before the fix: reproduced the incorrect newly-queued claim; evidence-before contains the reply and actual emitted snapshot.
- `TMPDIR="$PWD/.ahoy-validation/tmp" GIT_CEILING_DIRECTORIES="$PWD/.ahoy-validation/tmp" bash tests/fm-bearings-snapshot.test.sh`: failed with the new prior-value assertions before the fix; passed after the fix, including first/repeat looks, added versus changed rows, partial blocker clearance, disappearances, checkpoint recovery/compactness, skipped publication verification, and queue immutability.
- `python3 .ahoy-validation/catchup.py` and `python3 .ahoy-validation/catchup-repeat.py` after the fix: two real native Claude /ahoy calls gathered through the executable and described the existing guide as unblocked, without empty inventories or contribution counts. Both retained the honest contribution-coverage disclosure. Matching replies, checkpoints, CLI transcripts and emitted snapshots are saved in evidence-after and evidence-after-repeat.
- `python3 .ahoy-validation/preservation.py`: real Claude evaluations using the current skill and fresh executable output passed first/repeated quiet, 71 action-free cached contributions, unreadable contribution coverage, and a completed worker whose endpoint is absent. Replies omitted empty inventories/counts and retained uncertainty. These are development-only model evaluations, not deterministic CI.
- `python3 .ahoy-validation/completion.py`: current-skill evaluation against the previously captured real completed-worker snapshot ../live-real-worker-complete.json retained done state and unverified publication/CI without an empty Needs you section. This reused recorded public output; it did not launch a new worker.
- Shared live fixture: sourced tests/lib.sh and tests/ahoy-live-helpers.sh, executed ahoy_live_home, gathered with the real fm-bearings-snapshot.sh, asserted the public transition from ["-","delivered"] to ["-","-"], and exercised ahoy_live_assert against each verified native reply. Passed; the queue stayed unchanged and the checkpoint refreshed.

## Harness fixture refresh and blocked live checks

Both Pi and OpenCode fixtures injected AHOY_BEARINGS_BRANCH through a test-only Bearings skill that current Ahoy never invokes.
They now include the real snapshot executable/dependencies, exercise /ahoy first and later in a session, and assert observable delivery, existing queue unblocking, a fresh checkpoint and queue immutability.
The retired sentinel and old later-message no-gather expectation were removed.
Ahoy-only test selectors stop before unrelated watcher continuity scenarios.

`TMPDIR="$PWD/.ahoy-validation/tmp" GIT_CEILING_DIRECTORIES="$PWD/.ahoy-validation/tmp" FM_PI_LIVE_E2E=1 FM_PI_LIVE_AHOY_ONLY=1 bash tests/fm-pi-primary-live-e2e.test.sh`
failed at its first model invocation with: `No API key found for openai-codex.`
No credentials, account configuration, or model selection were changed. Pi's live verdict remains unverified.

`TMPDIR="$PWD/.ahoy-validation/tmp" FM_OPENCODE_LIVE_E2E=1 FM_OPENCODE_LIVE_AHOY_ONLY=1 bash tests/fm-opencode-primary-live-e2e.test.sh`
failed its capability gate: `not ok - FM_OPENCODE_LIVE_E2E was requested but opencode is not installed`.
No installation or host search was attempted. OpenCode's live verdict remains unverified.

A first completion-evaluation attempt used an overly long private tmux socket path and failed before invoking Claude; moving its disposable home to the short worktree-local c/ path fixed the setup, and the evaluation passed.

No full repository suite, linter, formatter, static analyzer, push, PR, CI phase or pipeline-control command was run.
Disposable homes, copied checkouts, sockets and worktree-local validation artifacts were removed after archiving this evidence.
