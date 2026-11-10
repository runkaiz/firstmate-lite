Focused completion-chat re-evaluation

The original saved reply rendered **Needs you: Nothing right now.** A fresh pre-fix real Claude run reproduced the unheaded variant, Nothing needs you right now. Its real snapshot contained no decisions or captain contributions, and the worker remained done with unverified publication and CI.

The initial wording revision still produced unheaded reassurance. Removing the general all-clear allowance and explicitly omitting unheaded empty-state filler passed two fresh real Claude executions, using the same prompt and actual snapshot executable. Both retained an honest publication/CI caveat on the completed work row and omitted both the action heading and reassurance. The snapshot semantic payload was identical before and after, excluding observation timestamps and elapsed time.

Commands: python3 .ahoy-fix-eval/evaluate.py before; python3 .ahoy-fix-eval/evaluate.py after; python3 .ahoy-fix-eval/evaluate.py after-removal; python3 .ahoy-fix-eval/evaluate.py after-confirm. Preserved driver: driver-fix-chat.py. Actual transcripts, replies, snapshots, commands, and focused assertion results are saved alongside this record. This is a development-only model evaluation, not deterministic CI coverage or a guarantee across models. Native slash discovery was not evaluated.

Setup: a private tmux session and all lab state lived inside the worktree. A too-long Unix socket path was corrected to a shorter worktree-local path. No full test suite, linters, formatters, other pipeline phases, or publication commands were run.
