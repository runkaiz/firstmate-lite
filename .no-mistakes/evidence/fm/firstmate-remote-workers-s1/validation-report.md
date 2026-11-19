# Remote-worker live validation

Target: `9631eb1464edb598ae982b1b24d6e29d67b70206`.

Result: **go within the recorded pilot scope**. No product or tracked test changes were needed.

The real pegasus Herdr 0.9.5 server and Claude Code 2.1.328 were exercised through the captain-approved test profile and SSH alias. A marked disposable home and local-only repository stayed inside the gate worktree. At most one test workspace existed at a time. The original captain workspace/tab (`w1R` / `w1R:t1`) stayed focused throughout and after cleanup. No screenshots, Xcode, build VM, or remote GitHub operations were used.

| Scenario | Evidence and result |
| --- | --- |
| Explicit machine opt-in and supported scope | Real CLI rejected a saved-but-unconfigured profile, unsupported delivery, another harness, scout mode, and malformed machine configuration before allocating a remote task. |
| Real Claude placement and custody | Claude processed its instructions in auto mode without a trust prompt, committed `hello.txt` as `0bde7e459a293b99b5d64c8ffd00c427c09b0080`, and the courier imported that commit onto the named local landing branch with its status. Identity used profile id plus remote pane id. |
| Lost initial workspace response | The real workspace-create response was deliberately dropped after successful creation. The launch token recovered exactly one tab in workspace `w1X`; Claude completed the trivial retry task. No duplicate or focus change occurred. |
| Interrupted journal plus concurrent local answer | A real status import exited at its supported after-journal crash point. The next actual SSH response was delayed while `fm-send --resolve-key live-race` recovered the journal. The stale chunk did not advance the recovered cursor or duplicate/reopen the decision. The next pass delivered the remaining line once, without a continuity alert. |
| Connection outage and return | Only the pilot alias pointed to `192.0.2.1`. The real courier recorded unreachable; current worker declaration remained working with unknown liveness. Exit, relaunch and cleanup refused; metadata and custody records remained intact. The actual monitoring loop (8-second grace, 1-second signal grace/poll) emitted one outage notice, no stale notice or retry-budget changes, and one return notice. Two remote status lines arrived in order once. Claude acknowledged all queued messages once; `outage-ack-once` appeared exactly once. |
| Preservation, landing and resumable removal | Ignored unique data and detached HEAD each refused cleanup while Claude remained running. Local main fast-forwarded through `fm-merge-local.sh`. Cleanup preserved detached commit `d052ee1d714606de8be08e2ce50f5929eb4e6677` in a local history ref and verified the archived channel scratch bytes. A transport fault exited the real remote shell immediately after successful `git worktree remove`; the persisted removing phase resumed branch/folder removal on retry. Normal teardown completed both sides. |
| Direct-PR publication | **Portable-only by explicit operator decision.** `tests/fm-remote-task.test.sh` passed verified-commit, authority/destination mismatch, crash recovery and PR retry cases using stand-ins. No live push or PR was attempted. |
| Artifact removal | Both workers, their remote task folders/cache, five pilot trust entries, two matching Claude session trees/environments, test profile/alias and both local disposable homes were removed. No courier temporary files remained. `ssh pegasus true` and the unchanged captain profile still worked; original focus remained. |

Both focused regression scripts passed: `bash tests/fm-remote-task.test.sh` and `bash tests/fm-remote-watch.test.sh`. The complete suite, linters, formatters, push, PR and CI phases were not run.

`live-pilot.log` contains chronological actual commands, product output and state assertions. `live-outage-down-1.log` and `live-outage-return-0.log` contain the real monitoring notices. `preserved-ignored.txt` and `channel-artifact-proof.txt` contain the unique fixture bytes retained during preservation checks. `driver-*.py` retain the corrected disposable drivers; chronological logs also retain earlier driver setup retries. Those retries corrected quoting/expectations, the signal-grace wait, per-command signing for a noninteractive SSH fixture commit, and SSH pass-through for the fault injector; they did not require product changes.

This is a CLI/runtime change. Reviewer-visible evidence is terminal/API output and persisted custody state; host screenshots were explicitly forbidden by C4.
