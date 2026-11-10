Mode: Claude Stop-hook-owned supervision.

When this session owns supervision and away mode is not active:
1. Drain first with `bin/fm-wake-drain.sh`; after handling everything, run the exact `--ack-through` command printed as `WAKE_ACK_REQUIRED`.
2. The Stop `asyncRewake` hook (`bin/fm-claude-stop-autoarm.sh`) owns every watcher arm and re-arm, never you; an actionable close wakes you as a `Stop hook feedback` message.
3. On a `Stop hook feedback` wake (`signal:`, `stale:`, `check:`, or `heartbeat`), drain first and handle the wake; do not run `bin/fm-watch-arm.sh`, and act only on real wake records, the drain's `OPEN DECISIONS` and `UNREAD STATUS` entries, or a real watcher reason line, never an attach-status line alone.
4. On the one automatic-mechanism failure notice (`firstmate watcher auto-arm FAILED ...`), drain and inspect the failure without turning it into a repeating manual-arm loop.
5. If the Stop hook does not claim the home or reports an exhausted failure, inspect its registration and watcher startup path before ending blind; the turn-end guard (`bin/fm-turnend-guard.sh --claude`) is the final backstop.
6. Waiting on the hook-owned cycle is silent.

[`watcher-continuity.md`](../watcher-continuity.md) and [`turnend-guard.md`](../turnend-guard.md) own the arm, successor, and guard mechanics.
