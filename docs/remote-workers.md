# Remote workers

A remote worker runs in a tab of another machine's Herdr server, next to that machine's tools, while its task records, the one supervision loop, the backlog, and landing stay on this machine.
Nothing is installed on the remote machine and it makes no decisions: it holds a bare repository cache, one folder per task, and the worker's own Claude login.
This page owns the operator contract; `bin/fm-remote-task.sh` (provisioning, the courier, publication, retirement) and `bin/backends/herdr-remote.sh` (machine configuration, endpoint identity, backend primitives) own the mechanics in their headers.

## What is supported

- Claude Code ship workers with `local-only` or `direct-PR` delivery.
  No-mistakes delivery, scouts, other harnesses, presentation spaces, and Herdr push events are not supported for remote tasks yet.
- One saved Herdr machine profile per remote machine, reached from this machine over SSH.
- The native task-copy allocator (`config/worktree-allocator` set to `git`); the landing copy here is allocated exactly as a local task's.

## Setup

1. Save the machine in Herdr on this machine (`herdr machine add`), and confirm `herdr machine status <label> --json` reads `reachable`.
   Firstmate never adds, removes, enables, or reconnects a profile, and never starts, restarts, or replaces the remote Herdr server.
2. List it in the private `config/remote-machines`, one line per machine: `<herdr-profile-id> <label> [<remote-root>]`.
   The root defaults to `~/firstmate-remote`; `#` starts a comment, and a malformed line refuses every read rather than being skipped.
   Firstmate never dispatches to a machine merely because Herdr knows it.
3. The remote account needs `git`, `perl`, `python3`, `lsof`, and `ps`, a Claude Code login usable from its Herdr panes, and SSH access from this machine without a prompt.

## Dispatch

Scaffold the brief with `bin/fm-brief.sh <id> <repo> --mode <local-only|direct-PR> --machine <label>` and spawn with `bin/fm-spawn.sh <id> <project> --machine <label> --mode <mode> --yolo <on|off>`.
The brief's status file, inbox, and scratch space are on the remote machine, its copy is already on the task branch with no git remote, and `bin/fm-dod-lib.sh`'s `fm_remote_dod_block` owns its delivery contract.
The worker uses the remote machine's own Claude login in `auto` permission mode; this machine's worker account pin and quota checks do not apply.

The spawn creates the tab with `--no-focus` in one remote workspace labeled `firstmate`, recorded by exact id; the captain's own workspaces are never addressed or touched.
If focus moved onto the new tab it is moved back to the exact tab recorded just before; if it moved anywhere else it is left alone and reported.
A random launch token in the tab label lets a retry after a lost create response adopt exactly one match; several matches, or an unrecorded `firstmate` workspace, refuse.
A remote task records `backend=herdr-remote` and `window=<profile-id>:<pane-id>`, so its key can never equal a local `<session>:<pane-id>` key.

## The courier

`bin/fm-remote-task.sh sync <machine>` makes one SSH call per machine per pass, and the watcher starts it in the background at most every 30 seconds while that machine has live remote tasks.
Each pass imports, in this order:

1. **Commits.** The remote branch is fetched into `refs/firstmate/remote/<id>`, a detached remote `HEAD` into `refs/firstmate/remote/<id>-head`, and the landing copy here is fast-forwarded onto the named branch and checked out on it.
   A non-fast-forward is never forced; it raises a finding.
2. **Status lines.** Only complete lines are imported, exactly once, through a per-task journal that survives a crash at any step.
   A replaced or shortened remote log stops import for that task and raises a finding; the offset is never reset silently.
3. **Instructions.** `bin/fm-send.sh` only queues a remote steer here.
   The courier places it remotely once (a receipt directory makes a retry harmless), rings the doorbell only after placement is confirmed, and moves the local record to `handled/` when the worker acknowledges it remotely.
   Keys are never sent to a remote worker.
4. **Process rows.** The processes below the pane shell are recorded, so liveness and the agent-free proof come from the remote machine's own process table, never from this machine's.

Every finding lands in `state/<id>.remote-alert` and reaches firstmate as one check notification.

## When the machine is asleep, offline, or disconnected

The courier keeps one link record per machine (`state/.remote-link-<profile-id>`), separate from every task's own status:

| Observation | Meaning | Effect |
| --- | --- | --- |
| `unreachable` | SSH failed or timed out | No stale, transition, or inbox notification; no ring and no retry budget spent; liveness reads unknown, never dead; lifecycle control and cleanup refuse with every record intact |
| `herdr-unavailable` | SSH works, but the remote Herdr did not answer | Same as `unreachable` |
| task folder missing | Everything answers, but the task's remote folder or copy is gone | That task is skipped and reported once; cleanup refuses until firstmate reports what was last imported and asks |
| `reachable` | Everything answers | Ordinary supervision, from imported status lines and Herdr's own agent state |

A worker that wrote `done:` or opened a decision still reads that way during an outage.
One check notification fires after ten minutes down with live remote tasks, and one when the machine returns; queued instructions are then placed and status lines and commits catch up in order.
Firstmate mentions an outage to the captain only when something the captain is waiting on is stuck behind it.
Anything the worker did after the last successful pass exists only on the remote machine; losing that machine loses it.

## Publication (direct-PR)

The worker commits, writes the PR text to `channel/publish/<sha>.md`, and appends a `paused [key=publish-<sha12>]` publication request; it never writes `done:` and never reaches the forge.
After the courier imports that commit and text, `bin/fm-remote-task.sh publish <id> <sha>` refuses unless the custody ref, the landing copy's branch, and its `HEAD` all equal `<sha>`, the copy is clean, and `<sha>` contains the recorded base.
It then pushes exactly `<sha>` to the task branch without force, finds or opens one ready PR with explicit `--repo`, `--head`, and `--base`, reads it back, records `pr=` and the `done:` line, and tells the worker the URL.
Merging stays with `bin/fm-pr-merge.sh` under the ordinary merge authority.
A `local-only` remote ship lands through the unchanged `bin/fm-merge-local.sh`, because its commits are already on the landing copy's named branch.

## Cleanup

`bin/fm-teardown.sh` runs the remote phases first and records them in `state/<id>.remote-retire`, so a lost connection resumes safely:

1. **Quiesce:** run the remote proof of step 3 once read-only, so unimported work refuses while the worker is still live to tidy it up; then close the exact recorded tab under the focus rule below and confirm no process works inside the remote task folder.
2. **Final transfer:** one more courier pass; any finding refuses.
3. **Remote proof:** no staged, untracked, or ignored file, `HEAD` on the task branch and equal to the last imported commit, no stash, and nothing in the task folder but `wt`, `channel`, `launch.sh`, and `settings.json`.
4. **This machine's proof:** the unchanged native landed-work proof on the landing copy.
5. **Remote removal:** the proof runs again immediately before `git worktree remove` without force, the cache branch is deleted only when it equals the imported commit, and the exact task folder is removed; `removing` and `removed` are recorded around it.

Any unreachable or unproven state refuses with every record intact.
The close rule has no plain-close fallback: it defers when the tab is the focused tab, when closing would empty the focused workspace, or when focus cannot be read.
Session start lists remote task folders the last courier pass saw without a record here, and never deletes them; the repository cache outlives tasks and may be deleted by hand once no task uses it.

## Access and trust

A remote worker runs as the remote account and can reach whatever that account reaches, including its SSH keys, keychain, and files.
Its copy has no git remote and firstmate gives it no token, but that prevents accidents, not intent: keeping forge publication on this machine is a working rule, not a boundary.
This is the same trust a local worker already holds, extended to that machine; a separate, credential-free account is the enforceable alternative.

## Verification

`tests/fm-remote-task.test.sh` covers the portable contract with SSH, Herdr, and gh stand-ins.
The live pilot evidence for the first machine lives in that task's private report.
