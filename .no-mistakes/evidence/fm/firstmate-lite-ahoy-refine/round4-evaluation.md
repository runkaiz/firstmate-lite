# Ahoy live evaluation, round 4

The current Ahoy skill and real snapshot executable passed the live scenarios.

- Delivery rows carry a merged PR URL, local-main marker, or completed scout report; folded and artifact-free closures stay out.
- Conditional and future-dated holds stay deferred, including detail mode. Only the active route choice appears under Needs you. Conflicting deferral arguments are refused without queue mutation.
- First and unchanged looks, corrupt checkpoint recovery, protected symlink refusal, and read-only monitoring behave correctly.
- Answered calls and removed queue/worker rows become no-longer-observed changes rather than deliveries. Clearing a dependency appears in the comparison.
- Running work retains its full title, implementing stage, and roughly 15-minute elapsed time.
- Two completion replies preserve unverified publication/CI and omit an empty Needs you section.
- Quiet, restored-quiet, and quiet-with-71-cached-contributions replies omit empty inventories and contribution counts.
- Four incomplete-coverage quiet replies contain only the comparison and one short uncertainty disclosure.

See round4-ahoy-live-replies.html for actual model replies, corresponding round4-chat-*-snapshot.json files for the executable output consumed in each reply, and round4-live-cli-transcript.txt for CLI transitions and refusal cases.

Isolation: marked disposable FM_HOME inside the worktree; private fm-lab tmux socket, 120x40 sessions; machine's existing Claude login; safe print mode with no session persistence. The lab and private tmux server were removed by the driver cleanup blocks.

The initial snapshot behavior test run failed because Git discovered the containing worktree's origin from non-repository fixture directories. Re-running with GIT_CEILING_DIRECTORIES set to the disposable fixture parent passed. This required no source changes.

Screenshot capture was attempted with chrome-devtools-axi in a private workspace-local session. It returned BRIDGE_NOT_READY because the attached CDP target was unavailable. The reviewer-visible HTML transcript preserves the real emitted chat copy; no screenshot was captured.

Final targeted checks: isolated fm-bearings-snapshot.test.sh, fm-queue.test.py, and fm-captain-hold-lifecycle.test.sh exited successfully. Optional legacy beads cases skipped on the markdown-only tasks-axi installation. Final git status is clean and all disposable directories are absent.
