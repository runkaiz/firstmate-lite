<h1 align="center">Firstmate-lite</h1>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

```
                 |    |    |
                )_)  )_)  )_)
               )___))___))___)
              )____)____)_____)
            _____|____|____|_____
   ~~~~~~~~ \     you're the     / ~~~~~~~~
     ~~~~~~~ \_____captain_____/ ~~~~~~~
```

## Ahoy

You are the captain.
You talk to exactly one agent, the first mate.
The first mate sends each job to its own worker (a separate coding agent) in its own isolated copy of the project, keeps an eye on all of them, and only comes back to you with finished work or a real decision.
No more juggling five terminals and forgetting which one had the failing test.

This repository *is* the first mate: a set of instructions, skills, and small scripts that turn the coding agent you already use (Claude Code, Pi, and friends) into a crew boss.

## Get going

### 1. Gather the crew's gear

On a Linux machine you need:

- A supported coding agent, logged in to its own account; the walkthrough below uses Claude Code.
- `git`, Node.js, and Python 3.9+ for the built-in backlog.
- [Herdr](https://herdr.dev) (the terminal workspace where workers get their own tabs), `jq`, and `treehouse` (hands out isolated copies of your project).
  `tmux` works as a simpler fallback when Herdr is not installed.
- For the default GitHub workflow: the `gh` CLI, logged in with `gh auth login`, and `no-mistakes` (the review-and-ship pipeline).

You do not have to get this list perfect.
On its first start the first mate checks what is missing, prints install commands or manual instructions, and asks before installing anything.
Local-only work needs neither GitHub login nor `no-mistakes`; plain PRs need GitHub tooling without the validation pipeline.
The full list per workflow lives in [the toolchain reference](docs/configuration.md#toolchain).

### 2. Install it

```sh
curl -fsSL https://raw.githubusercontent.com/runkaiz/firstmate-lite/main/bin/fm-install.sh | bash
cd ~/firstmate
```

The installer keeps shared code in `~/.local/share/firstmate` and private records in `~/firstmate`.
Existing clone-and-run setups still work, with [optional migration and alternate paths](docs/configuration.md#installing-a-separate-home).

### 3. Launch your first mate

Start Herdr so you can watch the workers appear as tabs, then start your agent in its pane:

```sh
herdr
bin/fm-start.sh claude
```

Without Herdr, run `tmux new -s firstmate` before starting the agent.

For a separate home, use `bin/fm-start.sh codex` or `bin/fm-start.sh pi` to switch agents.
From a combined checkout, launch the agent directly:

| Agent | Launch | First-time note |
| --- | --- | --- |
| Claude Code | `claude` | - |
| Pi | `pi` (or `FM_PI_HARNESS=pi-signed pi-signed` for the signed wrapper) | Approve the project trust prompt once. |
| Oh My Pi | `omp` | Use `FM_OMP_HARNESS=omp omp` when starting inside a Claude Code pane. |
| Grok | `grok --trust` | `--trust` loads the project hooks. |
| Cursor Agent | `cursor-agent --trust` | Run it interactively, not with `-p`. |
| Codex, OpenCode | `codex`, `opencode` | See their [supervision limits](docs/turnend-guard.md). |

### 4. Say hello

```
> ahoy! clone github.com/you/my-app and fix the flaky login test
```

The first mate clones the project, writes the worker's instructions, and sends it off.
A while later:

```
  Captain, the flaky login test is fixed and checks are green:
  https://github.com/you/my-app/pull/42 - merge it?

> merge it
```

A few handy commands once you are under way:

Use the slash form below in Claude Code and Grok; in Codex use `$ahoy`, `$afk`, `$sparespeed on|off|status`, `$stow`, and `$updatefirstmate`.

- `/ahoy` - a ten-second catch-up: what shipped, what is moving, what is next, and what needs me.
- `/afk` - I'm stepping away; keep the crew going and brief me when I'm back.
- `/sparespeed on|off|status` - let Codex workers run in [fast mode](docs/configuration.md#worker-fast-mode) only while spare quota before the reset allows it.
- `/stow` - save what we learned before I close the session.
- `/updatefirstmate` - pull the latest Firstmate-lite safely.

Ahoy compares current records with your last look and shows only sections with something to report; it is also the view of your task queue, so you never need a queue command.
Use `/ahoy detail` for more local detail, `/ahoy lavish` (or `visual`) for the interactive board, and `/ahoy live` (or `include PRs`) for live GitHub PR checks.
The old `/bearings` alias and `/ahoy file` mode are retired.

## What it does for you

- **One conversation** - you never manage workers directly; the first mate dispatches, supervises, and summarizes.
- **Parallel work** - each task gets its own worker and its own copy of the project, so several fixes can run at once.
- **Two kinds of jobs** - a *ship* produces a change (a pull request or a local merge); a *scout* investigates and hands you a written report.
- **Your delivery style, per project** - pick full review-and-PR, a plain PR, or local-only branches for each project.
- **Quiet supervision** - a tiny background watcher waits without spending model tokens, then wakes the first mate when attention is needed.
- **Survives restarts** - everything is written to disk, so a new session picks up where the last one left off.

## How it keeps you safe

- **You set merge authority** - see the [project delivery rules](docs/architecture.md#delivery-modes-are-explicit-per-task) and optional [proactive mode](docs/configuration.md#proactive-preference-configproactive).
- **Isolated copies** - workers implement changes in separate worktrees; the first mate's narrow project-write exceptions are defined in [hard rule 1](AGENTS.md#1-identity-and-prime-directives).
- **No work gets thrown away** - uncommitted or unmerged work is never deleted without your explicit say-so.
- **Start with your own home** - do not copy another operator's private records or settings into a fresh checkout; see the [home layout](docs/configuration.md#operational-home-layout-and-state).
- **It cannot publish upstream on its own** - pushing, filing issues, or opening PRs against Firstmate's own repository needs a [maintainer opt-in or your per-task consent](docs/configuration.md#firstmate-role-configfirstmate-role).
- **It asks before installing tools** and before anything destructive, irreversible, or security-sensitive.

## Honest limits

Current Firstmate-lite evidence covers CPU-only Linux fixtures.
That does not prove a fresh install, provider login or service-tier behavior, live worker lifecycles, or macOS compatibility.
Inherited [verification records](docs/verification/runtime-backends.md) apply only to their stated versions and scopes.
Nested supervision, Relay, alternate forges, and the bundled dashboard are outside this fork's scope.
The retained [remote command transport](docs/configuration.md#remote-commands-configremote-routes) does not provide standalone remote coding-agent dispatch.
How well it runs still depends on your agent, your terminal backend, and the tools above; it is lean, not dependency-free.
If something breaks, tell the first mate what you saw - diagnosing its own setup is part of the job.

## Learn more

- [docs/configuration.md](docs/configuration.md) - every setting, file, and supported agent.
- [docs/architecture.md](docs/architecture.md) - how the crew, supervision, and isolated copies fit together.
- [docs/herdr-backend.md](docs/herdr-backend.md) - watching and steering workers in Herdr, the default backend.
- [docs/tmux-backend.md](docs/tmux-backend.md) - the tmux fallback.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - an alert for when an away-mode notification gets stuck.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt.
- [AGENTS.md](AGENTS.md) - the first mate's full job description.
- [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/documentation-audiences.md](docs/documentation-audiences.md) - how to contribute and where docs belong.

## Credits and license

Firstmate-lite is a lean derivative of [Firstmate](https://github.com/kunchenguid/firstmate), originally authored by Kun Chen.
It keeps Firstmate's `fm-*` commands and file names for compatibility.
MIT licensed, with the original license and attribution preserved in [LICENSE](LICENSE).
