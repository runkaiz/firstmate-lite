# Initial Test verification

Run: `01M5Z7HH87MVR9K988M9MEHRVD`
Head: `072a4c788d97fca34e96a5c04c0b27579467a574`
Result: **inconclusive**, pending separately authorized outer-driver evidence.

## Commands executed serially

```sh
timeout 590 bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 180 tests/fm-afk-contract.test.sh tests/fm-control.test.sh tests/fm-control-relaunch.test.sh
timeout 590 bin/fm-test-run.sh --jobs 1 --per-script-timeout-secs 280 tests/fm-branch-supervision.test.sh tests/fm-project-capacity.test.sh
```

Both invocations exited 0, taking approximately 86 and 48 seconds respectively.
Each selected subject exited 0 with `gate_skip=false`.
No full suite, lint, model, real primary, or Herdr lifecycle was run.

## Observed deterministic behavior

- Away-record checks preserved explicit and legacy finite limits across replacement words and accepted the unspecified-cap sentinel.
- The staged fixture reproduced 16 occupied records against cap four; supported parking admitted the handoff while preserving task identity, continuation notes, unmerged bytes, and deferred status.
- Unknown or absent endpoints and stale stop receipts retained occupancy; an unattributed holder restored the capacity refusal.
- Relaunch reacquired capacity after another holder was parked, preserved that holder's record, and retained the replacement's reservation during provider startup.
- Branch-supervision checks exercised emitted prompt, outcome, lease, and mutation-guard interfaces.
- Project-capacity checks refused exhausted capacity before creating task records, endpoints, or worktrees, including concurrent admission and shared project limits.

These suites use synthetic fixtures and provider stubs where applicable.
Their passing assertions are not live vendor lifecycle or model-decision evidence.
The relaunch suite's final cleanup encountered read-only generated hook directories; the exact disposable fixture root was made writable, removed, and its absence verified.
No source changes were made.

## Direct product CLI evidence

`away-cap-cli.txt` records actual calls to `bin/fm-afk-contract.sh` in a disposable home, without a provider stub or model.
The transcript shows entry with numerical mandate words retaining `-`, an explicit cap of four surviving replacement words, an explicit revision to two, and rejection of zero without altering the existing cap.
The home was removed after verification.

## Pending required scenario

The full post-fix real-host/watcher scenario remains untested.
It must demonstrate a supervisor-created delivery hold, exactly one escalation, a silent unchanged follow-up with the host's genuine generation-bound acknowledgement, preserved files and unknown endpoint records, and stopped owned runtime with fixture archival.
No same-run, exact-head real-host evidence was supplied for inspection.
The current approved policy expressly reserves execution to the outer driver after a separate MAIN grant binding the run, head, script, prompt, and command.
Deterministic fixtures cannot establish that a model follows the revised decision contract.
No substitute experiment or previous-run evidence was used to claim success.
