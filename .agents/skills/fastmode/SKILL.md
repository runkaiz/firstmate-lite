---
name: fastmode
description: Set or inspect worker fast mode on /fastmode, /fastmode on, /fastmode off, or /fastmode status.
user-invocable: true
metadata:
  internal: true
---

# Fast mode

Run `bash bin/fm-fastmode.sh` with the requested action in the effective Firstmate home.
Bare `/fastmode` shows status.
For status, use the current override or dispatch configuration to identify the next Codex worker's model, then pass it as the second script argument.
Use a single default Codex profile as an estimate when no task-specific selection is known and label the estimate with its model.
If no explicit model can be identified, run status without a model.
Report the script's result, including that a qualifying quota estimate is checked again at launch.
