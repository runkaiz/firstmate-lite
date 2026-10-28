# Native archive compatibility: live CLI evidence

Target: `c1fc73d402511a5fa7b8f175c125920421e8b66d`.

Sixteen targeted behavioral tests executed the real shipped `bin/fm-queue.py` in disposable worktree-local queues. No product stubs, operator queues, fleet sessions, or live-home activation were used. Assertions passed for preserved archive bytes, selected history, refusal atomicity, idempotency, concurrent writers, and transaction recovery. All fixture directories were removed.

The transcript excerpts below are actual CLI responses. Complete command/output JSONL and final persisted queue records accompany every test. Paths inside transcripts name disposable fixtures that have been removed.

## Legacy archive reads, backup and append

[Complete CLI transcript](test_legacy_dated_archive_sections_are_completed_history.jsonl) · [Persisted records](test_legacy_dated_archive_sections_are_completed_history-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py migrate --dry-run --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/data/backlog.md
exit: 0
{"ok": true, "records": 6, "identities": 5, "ambiguous_histories": ["alpha"], "format": "compatible-markdown", "rewrite_required": false, "activated": false}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py migrate --backup-dir /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/backup --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/data/backlog.md
exit: 0
{"ok": true, "records": 6, "identities": 5, "ambiguous_histories": ["alpha"], "format": "compatible-markdown", "rewrite_required": false, "activated": false}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show beta --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "beta", "title": "Prerequisite", "state": "done", "kind": "scout", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-06", "links": ["data/beta/report.md"], "body": "", "archived": true}}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show gamma --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "gamma", "title": "Unrelated", "state": "done", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-07", "links": [], "body": "", "archived": true}}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show lookalike --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/data/backlog.md
exit: 1
code: NOT_FOUND
error: Task "lookalike" not found in this backlog or archive
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py ready --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/data/backlog.md
exit: 0
{"tasks": [{"id": "next", "title": "Follow-on", "state": "queued", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": ["beta"], "deps": ["beta"], "created": null, "closed": null, "links": [], "body": "", "archived": false}, {"id": "later", "title": "Uses alpha", "state": "queued", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": ["alpha"], "deps": ["alpha"], "created": null, "closed": null, "links": [], "body": "", "archived": false}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done delta --keep 0 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpjw2jgscc/data/backlog.md
exit: 0
ok: done delta
task:
  id: delta
  title: Native completion
  state: done
  kind: task
  repo: "-"
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: 2026-10-28
  closed: 2026-10-28
  links: none
  body: ""
  archived: yes
```

## Preview and explicit provenance select the latest completion

[Complete CLI transcript](test_explicit_history_link_resolves_latest_and_reopen_continues_it.jsonl) · [Persisted records](test_explicit_history_link_resolves_latest_and_reopen_continues_it-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1 --dry-run --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "recorded": false, "resolved": true, "order": ["done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)"]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 1
error: ambiguous archived identity alpha: archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09); inspect with show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 1
error: --predecessor and --successor must each name a different archived record; see show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --dry-run --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 1
error: --predecessor and --successor must each name a different archived record; see show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "recorded": true, "resolved": true, "order": ["done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)"]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true}}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py reopen alpha --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
ok: reopen alpha
task:
  id: alpha
  title: Follow-up delivery
  state: queued
  kind: task
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: "-"
  links: none
  body: Follow-up scope
  archived: no
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --keep 0 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
ok: done alpha
task:
  id: alpha
  title: Follow-up delivery
  state: done
  kind: task
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-10-28
  links: none
  body: Follow-up scope
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py reopen alpha --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
ok: reopen alpha
task:
  id: alpha
  title: Follow-up delivery
  state: queued
  kind: task
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: "-"
  links: none
  body: Follow-up scope
  archived: no
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --no-prune --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmplrn9u4lg/data/backlog.md
exit: 0
ok: done alpha
task:
  id: alpha
  title: Follow-up delivery
  state: done
  kind: task
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-10-28
  links: none
  body: Follow-up scope
  archived: no
```

## Single-record reopen preserves previous completion

[Complete CLI transcript](test_reopened_single_record_keeps_identity_and_appends_completion.jsonl) · [Persisted records](test_reopened_single_record_keeps_identity_and_appends_completion-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show gamma --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp65hwital/data/backlog.md
exit: 0
{"ok": true, "id": "gamma", "ambiguous": null, "records": [{"id": "gamma", "title": "Unrelated", "state": "done", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-07", "links": [], "body": "", "archived": true, "location": "done-archive.md:13 (Archived 2026-01-07, kind task, done 2026-01-07)", "digest": "sha256:ba18d5f294fa239e4090fd3c1300d9a1cd0fa90d6f4612e3f0b6a2f9767ced65#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py reopen gamma --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp65hwital/data/backlog.md
exit: 0
ok: reopen gamma
task:
  id: gamma
  title: Unrelated
  state: queued
  kind: task
  repo: "-"
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: "-"
  links: none
  body: ""
  archived: no
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show gamma --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp65hwital/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "gamma", "title": "Unrelated", "state": "queued", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": null, "links": [], "body": "", "archived": false}}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done gamma --keep 0 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp65hwital/data/backlog.md
exit: 0
ok: done gamma
task:
  id: gamma
  title: Unrelated
  state: done
  kind: task
  repo: "-"
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-10-28
  links: none
  body: ""
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done gamma --pr https://example.test/project/pull/2 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp65hwital/data/backlog.md
exit: 0
ok: done gamma
task:
  id: gamma
  title: Unrelated
  state: done
  kind: task
  repo: "-"
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-10-28
  links: https://example.test/project/pull/2
  body: ""
  archived: yes
```

## Late evidence preserves legacy completion verbs

[Complete CLI transcript](test_late_evidence_preserves_legacy_completion_verbs.jsonl) · [Persisted records](test_late_evidence_preserves_legacy_completion_verbs-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp707uu11i/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp707uu11i/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": null, "records": [{"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}, {"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --pr https://example.test/project/pull/2 --report data/evidence/report.md --note Additional evidence --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp707uu11i/data/backlog.md
exit: 0
ok: done alpha
task:
  id: alpha
  title: First delivery
  state: done
  kind: ship
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-01-04
  links: https://example.test/project/pull/1,https://example.test/project/pull/2,data/evidence/report.md
  body: "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)\n\nAdditional evidence"
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --pr https://example.test/project/pull/2 --report data/evidence/report.md --note Additional evidence --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp707uu11i/data/backlog.md
exit: 0
ok: done alpha
task:
  id: alpha
  title: First delivery
  state: done
  kind: ship
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-01-04
  links: https://example.test/project/pull/1,https://example.test/project/pull/2,data/evidence/report.md
  body: "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)\n\nAdditional evidence"
  archived: yes
```

## Ambiguous identities are refused without guessing

[Complete CLI transcript](test_repeated_archived_identity_is_refused_not_guessed.jsonl) · [Persisted records](test_repeated_archived_identity_is_refused_not_guessed-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show dup --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 1
error: ambiguous archived identity dup: archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, done 2026-01-04), done-archive.md:5 (Archived 2026-01-05, kind task, done 2026-01-05); inspect with show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py reopen dup --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 1
error: ambiguous archived identity dup: archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, done 2026-01-04), done-archive.md:5 (Archived 2026-01-05, kind task, done 2026-01-05); inspect with show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py add dup Reuse --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 1
error: identity already exists in active queue or archive: dup
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show dup --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 0
{"ok": true, "id": "dup", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, done 2026-01-04), done-archive.md:5 (Archived 2026-01-05, kind task, done 2026-01-05)", "records": [{"id": "dup", "title": "Private first title", "state": "done", "kind": "ship", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": [], "body": "Private first scope; digest sha256:00000000synthetic", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, done 2026-01-04)", "digest": "sha256:d6356281623b0b36674c2134d1232927c95bdc91e3301d05b39df6c8d78f75a8#1"}, {"id": "dup", "title": "Private second title", "state": "done", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-05", "links": [], "body": "", "archived": true, "location": "done-archive.md:5 (Archived 2026-01-05, kind task, done 2026-01-05)", "digest": "sha256:1b222dbc39dadb0badb57e125cfc9266d2cd86c5c852a22b90ab2ff20e86cb83#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py ready --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 0
{"tasks": [{"id": "other", "title": "Unrelated work", "state": "queued", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": ["dup"], "deps": ["dup"], "created": null, "closed": null, "links": [], "body": "", "archived": false}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show other --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "other", "title": "Unrelated work", "state": "done", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": ["dup"], "deps": ["dup"], "created": null, "closed": "2026-10-28", "links": [], "body": "", "archived": true}}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show dup --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 1
error: ambiguous archived identity dup: archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, done 2026-01-04), done-archive.md:7 (Archived 2026-01-09, kind task, done 2026-01-09); inspect with show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py reopen dup --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 1
error: ambiguous archived identity dup: archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, done 2026-01-04), done-archive.md:7 (Archived 2026-01-09, kind task, done 2026-01-09); inspect with show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py add dup Reuse --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 1
error: identity already exists in active queue or archive: dup
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py ready --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp99mn73kg/data/backlog.md
exit: 0
{"tasks": [{"id": "other", "title": "Unrelated work", "state": "queued", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": ["dup"], "deps": ["dup"], "created": null, "closed": null, "links": [], "body": "", "archived": false}]}
```

## Malformed, competing and cyclic links fail closed

[Complete CLI transcript](test_bad_history_links_stay_ambiguous.jsonl) · [Persisted records](test_bad_history_links_stay_ambiguous-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpslv3vadp/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09), done-archive.md:20 (Archived 2026-01-11, kind task, done 2026-01-11)", "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}, {"id": "alpha", "title": "Third delivery", "state": "done", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-11", "links": [], "body": "", "archived": true, "location": "done-archive.md:20 (Archived 2026-01-11, kind task, done 2026-01-11)", "digest": "sha256:1fbf229dc8cb01519629460dc188f760a336a8d99cb09f4288cb6076592522c1#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpslv3vadp/data/backlog.md
exit: 1
error: ambiguous archived identity alpha: archived history is not one linked chain (dangling history link); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09), done-archive.md:20 (Archived 2026-01-11, kind task, done 2026-01-11); inspect with show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpslv3vadp/data/backlog.md
exit: 1
error: ambiguous archived identity alpha: archived history is not one linked chain (competing history links); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09), done-archive.md:20 (Archived 2026-01-11, kind task, done 2026-01-11); inspect with show --history
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:1fbf229dc8cb01519629460dc188f760a336a8d99cb09f4288cb6076592522c1#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpslv3vadp/data/backlog.md
exit: 1
error: link would leave alpha with competing history links
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1 --successor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpslv3vadp/data/backlog.md
exit: 1
error: link would leave alpha with cyclic history links
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1 --successor sha256:1fbf229dc8cb01519629460dc188f760a336a8d99cb09f4288cb6076592522c1#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpslv3vadp/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "recorded": true, "resolved": true, "order": ["done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "done-archive.md:20 (Archived 2026-01-11, kind task, done 2026-01-11)"]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpslv3vadp/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "alpha", "title": "Third delivery", "state": "done", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-11", "links": [], "body": "", "archived": true}}
```

## Active/archive collision refuses mutation

[Complete CLI transcript](test_active_record_beside_archived_history_stays_refused.jsonl) · [Persisted records](test_active_record_beside_archived_history_stays_refused-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show beta --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpvskczldn/data/backlog.md
exit: 1
error: duplicate active/archive identity: beta; records: done-archive.md:10 (Archived 2026-01-07, kind scout, reported 2026-01-06), backlog.md:2 (Queued, kind task, undated)
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py add unrelated Do not guess --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpvskczldn/data/backlog.md
exit: 1
error: duplicate active/archive identity: beta; records: done-archive.md:10 (Archived 2026-01-07, kind scout, reported 2026-01-06), backlog.md:2 (Queued, kind task, undated)
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show beta --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpvskczldn/data/backlog.md
exit: 1
error: duplicate active/archive identity: beta; records: done-archive.md:10 (Archived 2026-01-07, kind scout, reported 2026-01-06), backlog.md:2 (Queued, kind task, undated)
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py add unrelated Do not guess --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpvskczldn/data/backlog.md
exit: 1
error: duplicate active/archive identity: beta; records: done-archive.md:10 (Archived 2026-01-07, kind scout, reported 2026-01-06), backlog.md:2 (Queued, kind task, undated)
```

## Cross-store moves of history refuse atomically

[Complete CLI transcript](test_cross_queue_history_moves_refuse_without_changing_either_store.jsonl) · [Persisted records](test_cross_queue_history_moves_refuse_without_changing_either_store-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done beta --report data/beta/extra.md --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/data/backlog.md
exit: 0
ok: done beta
task:
  id: beta
  title: Prerequisite
  state: done
  kind: scout
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-01-06
  links: data/beta/report.md,data/beta/extra.md
  body: ""
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done resident --keep 0 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/other/data/backlog.md
exit: 0
ok: done resident
task:
  id: resident
  title: Destination history
  state: done
  kind: task
  repo: "-"
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: 2026-10-28
  closed: 2026-10-28
  links: none
  body: Revised scope
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py mv alpha --to /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/other/data/backlog.md --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/data/backlog.md
exit: 1
error: unsupported cross-queue move for alpha: linked completion histories must remain in their current queue
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": null, "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py mv movable alpha --to /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/other/data/backlog.md --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/data/backlog.md
exit: 1
error: unsupported cross-queue move for alpha: linked completion histories must remain in their current queue
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py mv movable --to /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/other/data/backlog.md --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/data/backlog.md
exit: 0
{"ok": true, "moved": ["movable"]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py mv movable --to /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/data/backlog.md --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpd83_14q2/other/data/backlog.md
exit: 0
{"ok": true, "moved": ["movable"]}
```

## Interrupted late evidence recovers once

[Complete CLI transcript](test_late_evidence_after_linked_recompletion_recovers_once.jsonl) · [Persisted records](test_late_evidence_after_linked_recompletion_recovers_once-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpc2hpdoyy/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --keep 0 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpc2hpdoyy/data/backlog.md
exit: 0
ok: done alpha
task:
  id: alpha
  title: Follow-up delivery
  state: done
  kind: task
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-10-28
  links: none
  body: Follow-up scope
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpc2hpdoyy/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": null, "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-10-28", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:20 (Archived 2026-10-28, kind task, done 2026-10-28)", "digest": "sha256:33cf66aeb18fbb858acd0aaf0d29704a644eed0ae1351c576346ddb9085c04f8#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --pr https://example.test/project/pull/1 --report data/alpha/report-1.md --note Evidence 1
Retained detail --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpc2hpdoyy/data/backlog.md
exit: 91
fault injection: {"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "1"}

```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --pr https://example.test/project/pull/1 --report data/alpha/report-1.md --note Evidence 1
Retained detail --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpc2hpdoyy/data/backlog.md
exit: 0
ok: done alpha
task:
  id: alpha
  title: Follow-up delivery
  state: done
  kind: task
  repo: project
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: "-"
  closed: 2026-10-28
  links: https://example.test/project/pull/1,data/alpha/report-1.md
  body: "Follow-up scope\n\nEvidence 1\nRetained detail"
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done alpha --pr https://example.test/project/pull/2 --report data/alpha/report-2.md --note Evidence 2
Retained detail --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpc2hpdoyy/data/backlog.md
exit: 91
fault injection: {"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "2"}

```

## Concurrent links are recorded once

[Complete CLI transcript](test_concurrent_history_links_record_once.jsonl) · [Persisted records](test_concurrent_history_links_record_once-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpo3v3y099/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpo3v3y099/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "recorded": true, "resolved": true, "order": ["done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)"]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpo3v3y099/data/backlog.md
exit: 1
error: history link already recorded
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py link alpha --predecessor sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1 --successor sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpo3v3y099/data/backlog.md
exit: 1
error: history link already recorded
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmpo3v3y099/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true}}
```

## Concurrent archival preserves all legacy rows

[Complete CLI transcript](test_legacy_history_survives_crash_recovery_and_concurrent_writers.jsonl) · [Persisted records](test_legacy_history_survives_crash_recovery_and_concurrent_writers-state.json)

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done stable --no-prune --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp0_8gynoo/data/backlog.md
exit: 0
ok: done stable
task:
  id: stable
  title: Task
  state: done
  kind: task
  repo: "-"
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: 2026-10-28
  closed: 2026-10-28
  links: none
  body: ""
  archived: no
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py prune --keep 0 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp0_8gynoo/data/backlog.md
exit: 91
fault injection: {"FM_QUEUE_TEST_CRASH_AFTER_WRITES": "1"}

```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show stable --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp0_8gynoo/data/backlog.md
exit: 0
{"ok": true, "task": {"id": "stable", "title": "Task", "state": "done", "kind": "task", "repo": null, "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": "2026-10-28", "closed": "2026-10-28", "links": [], "body": "", "archived": true}}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py done id-0 --keep 0 --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp0_8gynoo/data/backlog.md
exit: 0
ok: done id-0
task:
  id: id-0
  title: Concurrent task
  state: done
  kind: task
  repo: "-"
  priority: "-"
  held: no
  hold_reason: "-"
  hold_kind: "-"
  hold_until: "-"
  blocked: no
  blocked_by: none
  deps: none
  created: 2026-10-28
  closed: 2026-10-28
  links: none
  body: ""
  archived: yes
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py show alpha --history --json --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp0_8gynoo/data/backlog.md
exit: 0
{"ok": true, "id": "alpha", "ambiguous": "archived history is not one linked chain (unlinked records); records: done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04), done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "records": [{"id": "alpha", "title": "First delivery", "state": "done", "kind": "ship", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-04", "links": ["https://example.test/project/pull/1"], "body": "Accepted first scope (kind: not-metadata)\n\n## Intent\n- [x] lookalike - not a row (done 2026-01-01)", "archived": true, "location": "done-archive.md:3 (Archived 2026-01-05, kind ship, merged 2026-01-04)", "digest": "sha256:d303440779b150c6e9c89ca74950da94bc9863d9f687e0cb5ce36f55293d0655#1"}, {"id": "alpha", "title": "Follow-up delivery", "state": "done", "kind": "task", "repo": "project", "priority": null, "held": false, "hold_reason": null, "hold_kind": null, "hold_until": null, "blocked": false, "blocked_by": [], "deps": [], "created": null, "closed": "2026-01-09", "links": [], "body": "Follow-up scope", "archived": true, "location": "done-archive.md:16 (Archived 2026-01-09, kind task, done 2026-01-09)", "digest": "sha256:72a8238c22097bc79e9220eb764aa18eb5cdb61f6eb3506ee2b5a9909214c1a3#1"}]}
```

```text
$ /var/home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/bin/fm-queue.py migrate --dry-run --file /home/runkai/.no-mistakes/worktrees/c4c55a3d9407/01M60RN1Z50R48Z1MGTDYM874F/.archive-live-qtnv05vs/tmp0_8gynoo/data/backlog.md
exit: 0
{"ok": true, "records": 13, "identities": 12, "ambiguous_histories": ["alpha"], "format": "compatible-markdown", "rewrite_required": false, "activated": false}
```

## Reproduction

`rtk proxy python3 /home/runkai/.no-mistakes/evidence/01M60RN1Z50R48Z1MGTDYM874F/archive-live-driver.py`

[Driver and exact test selectors](archive-live-driver.py) · [Targeted runner output](archive-targeted-results.txt)
