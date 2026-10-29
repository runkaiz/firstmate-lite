---
name: proactive
description: >-
  Toggle persisted proactive orchestration on /proactive, or load when startup or a wake reports proactive mode on.
  Supports /proactive on, /proactive off, and /proactive status.
user-invocable: true
metadata:
  internal: true
---

# Proactive

Run `bash bin/fm-proactive.sh` for a bare `/proactive`, or pass the explicit `on`, `off`, or `status` argument.
Use the effective home's environment; never infer the home from a project working directory.
The script's header and help own command mechanics and preference validation.
Report its actual result briefly, without claiming a failed write persisted.
After a successful change, run `bash bin/fm-proactive.sh instructions` and follow its current output immediately.
On status, read current instructions without toggling.
When startup already presented the policy, reuse it; on a wake's compact reference, load the policy only if absent from current context.
The conditional [policy](policy.md) is the sole behavior owner; it is emitted by the script only while on.
Off restores baseline orchestration and supersedes earlier proactive instructions in conversation memory.
This command changes no away/quiet posture, supervision owner, project delivery mode, or project yolo setting.
