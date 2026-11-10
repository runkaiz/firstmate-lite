# Final Ahoy live evaluation

All eight scenarios passed using the real snapshot/queue/hold executables and twelve real Claude Ahoy invocations with the current skill. The previously failing incomplete-coverage case passed four independent evaluations. Two completion replies retain publication/CI uncertainty and omit empty action sections. Ordinary quiet, restored quiet, and a quiet home containing 71 cached contributions emit no empty inventories or contribution counts.

The live CLI transcript covers artifact-backed deliveries, conditional and dated holds, full queued titles, first/unchanged/changed observations, answered calls and removed queue rows, structured blocker clearing, unchanged queue bytes, monitor-only checkpoint preservation, corrupt checkpoint recovery, symlink refusal, and conflicting deferral refusal. Actual harness chats add worker progress, completion, and worker disappearance coverage.

Isolation: freshly marked disposable FM_HOME inside this worktree, private fm-lab tmux server with 120x40 sessions, existing Claude login, safe print mode without session persistence, unrelated lifecycle/startup hooks disabled. The drivers tear down the lab and private server in finally blocks. No source edits were made.

Reviewer evidence: round5-ahoy-live-replies.html renders the actual emitted replies, and corresponding round5-chat-*-snapshot.json files contain the real executable output consumed by the model. round5-live-cli-transcript.txt contains commands and product responses. round5-live-evaluation-results.json records the reviewed outcomes.

Screenshot capture was attempted using chrome-devtools-axi with a workspace-local private profile. It failed with BRIDGE_NOT_READY because the attached Chrome/Electron CDP target was unavailable; no screenshot is claimed. The HTML transcript remains available as visual evidence.

The targeted snapshot, native queue, and captain-hold lifecycle test files all exited successfully. Legacy Beads compatibility cases were explicitly skipped by the existing hold test on this markdown-only tasks-axi installation. No linters, formatters, static analysis, full-repository suite, pipeline-control commands, publication, or CI phases were run. Test temporary files were removed after completion.
