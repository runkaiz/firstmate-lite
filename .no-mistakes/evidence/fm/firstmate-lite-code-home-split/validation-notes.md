Validated default and alternate installation, shared code across private homes, safe reinstallation, overwrite/nesting refusals, launcher cwd/environment/argv/exit behavior, separate queues, shared update preservation and guards, native instruction/skill/startup loading in Claude 2.1.322, Codex 0.167.1 and Pi 1.5.2, worker startup suppression, and linked-path watcher attachment/stop isolation.

Native CLI probes used a local HTTP capture endpoint and a unique skill in disposable installed code. HTTP 400 responses are intentional after request capture; no model response, provider login or remote service behavior is claimed. Codex trust was recorded for the physical path used by that CLI. Worker isolation was rechecked in a separate home after an initial snapshot raced primary cleanup.

Focused baseline: rtk bash bin/fm-test-run.sh --jobs 1 tests/fm-split-home.test.sh tests/fm-update.test.sh. Both passed. The split-home test includes a simulated tmux lifecycle, supplementary to the live checks above. No linter, formatter, static analyzer or broad suite was run.

Cleanup completed: all disposable homes, installs, source fixtures, private tmux sockets and test drivers were removed from the worktree; no source/test changes remain. The watched processes and lab tmux server were stopped before removal. Evidence remains in this directory.
