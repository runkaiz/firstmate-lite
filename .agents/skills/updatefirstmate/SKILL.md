---
name: updatefirstmate
description: >-
  Self-update a running firstmate from origin when the captain invokes /updatefirstmate or asks to pull the latest firstmate.
  Uses the guarded fast-forward path and re-reads the instruction surface when it changes.
user-invocable: true
metadata:
  internal: true
---

# updatefirstmate

Run `bin/fm-update.sh` for the current Firstmate code root only.
Updating consumes upstream changes and grants no publication authority; it does not update project clones or manage other agents.
The helper and `bin/fm-ff-lib.sh` own the clean-tree, default-branch, ancestry, and fetch checks; never force, stash, reset, or merge around a refusal.
Private operational directories remain untouched.

Read the helper's result faithfully, including skipped or failed updates.
When it prints `reread-firstmate: yes`, read the updated `AGENTS.md` before continuing and refresh any loaded skill whose instructions the new surface changes.
When it prints `reread-firstmate: no`, no instruction refresh was requested.
Do not claim that changing files reloads an already-running agent's launch-time wiring.
