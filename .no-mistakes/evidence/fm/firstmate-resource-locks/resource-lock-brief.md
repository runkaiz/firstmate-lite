# Heavy commands (resource locks)
This machine runs only a few of the heavy jobs named below at once, so take a slot yourself instead of asking firstmate.
Run each such command through its wrapper: it waits for a free slot, runs the command while holding it, and frees the slot when the command and any child processes retaining the lock have exited.
If a command needs more than one resource, nest wrappers from outermost to innermost in the order the resources are listed below (declaration order), so competing jobs do not deadlock.
Never run one of these commands outside its wrapper and never preempt another holder; a wait for a slot needs no `needs-decision`, and when your shell's command limit ends the wait, run the same wrapped command again.
- `suite` (2 at once, 1 during 22:00-09:00) - full test-suite runs: `/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ/bin/fm-resource-lock.sh run --file /home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ/.test-live/manual/home/config/resource-locks suite -- <command>`
- `gpu` (1 at once) - any GPU use: `/home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ/bin/fm-resource-lock.sh run --file /home/runkai/.no-mistakes/worktrees/6b05071b95c8/01M7E5G3VE4WRF2AH7TSMB9MDJ/.test-live/manual/home/config/resource-locks gpu -- <command>`
