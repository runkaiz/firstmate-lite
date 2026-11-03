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

There is nothing to install or build.
This repository *is* the first mate: a set of instructions, skills, and small scripts that turn the coding agent you already use (Claude Code, Pi, and friends) into a crew boss.
Open your agent inside this folder and it reads `AGENTS.md` and takes the job.

## Get going

### 1. Gather the crew's gear

On a Linux machine you need:

- A supported coding agent, logged in to its own account; [Claude Code](https://docs.claude.com/en/docs/claude-code) is the most exercised path.
- `git` and Node.js.
- `tmux` (the terminal multiplexer where workers get their own windows) and `treehouse` (hands out isolated copies of your project).
- For GitHub work: the `gh` CLI, logged in with `gh auth login`, and `no-mistakes` (the review-and-ship pipeline the crew uses by default).

You do not have to get this list perfect.
On its first start the first mate checks what is missing, prints the exact install command for each tool, and asks before installing anything.
The full list per workflow lives in [the toolchain reference](docs/configuration.md#toolchain).

### 2. Clone it

```sh
git clone https://github.com/runkaiz/firstmate-lite.git
cd firstmate-lite
```

Your own records (backlog, notes, project clones, settings) are created inside this folder under git-ignored paths, so they never get committed or shared.

### 3. Launch your first mate

Start a tmux session so you can watch the workers appear as windows, then start your agent:

```sh
tmux new -s firstmate
claude
```

Other supported agents launch the same way from this folder:

| Agent | Launch | First-time note |
| --- | --- | --- |
| Claude Code | `claude` | - |
| Pi | `pi` (or `FM_PI_HARNESS=pi-signed pi-signed` for the signed wrapper) | Approve the project trust prompt once. |
| Oh My Pi | `omp` | - |
| Grok | `grok --trust` | `--trust` loads the project hooks. |
| Cursor Agent | `cursor-agent --trust` | Run it interactively, not with `-p`. |
| Codex, OpenCode | `codex`, `opencode` | Supported, with more caveats than the ones above. |

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

- `/ahoy` - catch me up: what is in flight, what is waiting on me.
- `/afk` - I'm stepping away; keep the crew going and brief me when I'm back.
- `/stow` - save what we learned before I close the session.
- `/updatefirstmate` - pull the latest Firstmate-lite safely.

## What it does for you

- **One conversation** - you never manage workers directly; the first mate dispatches, supervises, and summarizes.
- **Parallel work** - each task gets its own worker and its own copy of the project, so several fixes can run at once.
- **Two kinds of jobs** - a *ship* produces a change (a pull request or a local merge); a *scout* investigates and hands you a written report.
- **Your delivery style, per project** - pick full review-and-PR, a plain PR, or local-only branches for each project.
- **Quiet supervision** - a tiny background watcher wakes the first mate only when a worker needs attention, so idle crews cost no tokens.
- **Survives restarts** - everything is written to disk, so a new session picks up where the last one left off.

## How it keeps you safe

- **Nothing merges without your word**, unless you explicitly turn on auto-merge for a project.
- **Isolated copies** - workers never touch your main checkout; the first mate itself only reads your projects.
- **No work gets thrown away** - unsaved or unmerged work is never deleted without your explicit say-so.
- **Your records stay local** - backlog, notes, settings, and project clones live in git-ignored folders on your machine.
- **It cannot publish upstream on its own** - pushing, filing issues, or opening PRs against Firstmate's own repository needs a [maintainer opt-in or your per-task consent](docs/configuration.md#firstmate-role-configfirstmate-role).
- **It asks before installing tools** and before anything destructive, irreversible, or security-sensitive.

## Honest limits

Firstmate-lite has been tested on Linux only, and a completely fresh machine install has not been proven end to end yet.
How well it runs still depends on your agent, your terminal backend, and the tools above; it is lean, not dependency-free.
If something breaks, tell the first mate what you saw - diagnosing its own setup is part of the job.

## Learn more

- [docs/configuration.md](docs/configuration.md) - every setting, file, and supported agent.
- [docs/architecture.md](docs/architecture.md) - how the crew, supervision, and isolated copies fit together.
- [docs/tmux-backend.md](docs/tmux-backend.md) - watching and steering workers in tmux.
- Other terminal backends: [Herdr](docs/herdr-backend.md), [Zellij](docs/zellij-backend.md), [Orca](docs/orca-backend.md), [cmux](docs/cmux-backend.md) (the last three are experimental).
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - an alert for when an away-mode notification gets stuck.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt.
- [AGENTS.md](AGENTS.md) - the first mate's full job description.
- [CONTRIBUTING.md](CONTRIBUTING.md) and [docs/documentation-audiences.md](docs/documentation-audiences.md) - how to contribute and where docs belong.

## Credits and license

Firstmate-lite is a lean derivative of [Firstmate](https://github.com/kunchenguid/firstmate), originally authored by Kun Chen.
It keeps Firstmate's `fm-*` commands and file names for compatibility.
MIT licensed, with the original license and attribution preserved in [LICENSE](LICENSE).
