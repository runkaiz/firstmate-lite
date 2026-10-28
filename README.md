<h1 align="center">Firstmate-lite</h1>

<h3 align="center">Talk to one agent. Ship with a crew.</h3>

## What it is

You can run one coding agent easily.
But the moment you want three project tasks done in parallel - fixes, investigations, plans, audits - you become a tab-juggler: babysitting sessions, copy-pasting context between repos, forgetting which terminal had the failing test.

Firstmate-lite is a lean derivative of [Firstmate](https://github.com/kunchenguid/firstmate), originally authored by Kun Chen.
It retains the `fm-*` commands and Firstmate operational file names for compatibility.
The original MIT license and attribution are preserved in [LICENSE](LICENSE).

Firstmate-lite flips the model.
You talk to a single agent - the first mate - and it runs the crew for you: spawning autonomous agents in a visible session backend, giving each a clean git worktree, supervising them to completion, and handing you finished PRs, approved local merges, or standalone investigation reports.

firstmate is not a model, not a harness, not a skill, not an MCP server, and not a CLI.
firstmate is an agent distro for running a crew of agents.
An agent distro is a portable directory of instructions, skills, tooling, policies, and state conventions that turns a general-purpose agent into a specialized one.
There is no app to install: the cloned repo is the distro - `AGENTS.md`, bundled firstmate skills, and helper scripts that any terminal coding agent can follow.
Launching a supported harness inside it for your primary session instantiates your first mate - and makes you the captain.

## Scope and limits

Firstmate-lite retains isolated ship/scout workers, per-project delivery and approval policies, durable task records, recovery, and event-driven supervision.
Nested secondmate supervision, Relay, alternate-forge workflows, and the bundled dashboard have been removed.
Generic remote command transport remains; it does not establish standalone remote coding-agent support.
The retained setup still depends on the selected harness, session backend, worktree provider, and workflow tools; this is not a dependency-free distribution.

The current release preparation has CPU-only Linux fixture evidence for conditional setup and project delivery policies.
That evidence does not establish a fresh machine installation, provider authentication, billing or service-tier behavior, live backend lifecycle, or macOS compatibility for this derivative.
Upstream verification records document their stated versions and scopes; they are not a blanket release certification for Firstmate-lite.
See the backend guides below for their individual limits.

## Features

- **One liaison** - you talk only to the first mate; it dispatches, supervises, escalates only real decisions, and reports plain outcomes.
- **A visible crew** - every crewmate works in its own tmux window or Herdr tab, or in an experimental Zellij tab, experimental cmux workspace, or experimental Orca terminal you can watch or type into; the first mate reconciles.
- **Disposable worktrees** - each task runs in a clean, isolated git worktree; [task allocator configuration](docs/configuration.md#task-worktree-allocator-configworktree-allocator) covers the available providers.
- **Two task shapes** - ship tasks deliver authorized changes; scout tasks leave standalone investigation reports when the intake contract warrants separate research.
- **Explicit project modes** - each project ships via `no-mistakes`, `direct-PR`, or `local-only`, with an optional `+yolo` merge-autonomy flag, an optional `branch=<prefix>` override for the default `fm/` ship-branch prefix.
- **Self-repo boundary** - a home runs as firstmate user/operator by default, so a firstmate bug is diagnosed and patched locally but never pushed, PRed, issued, commented, or forked upstream on its own; publishing to firstmate's own repository needs the `config/firstmate-role` maintainer opt-in or a per-task captain consent ([schema](docs/configuration.md#firstmate-role-configfirstmate-role)).
- **Event-driven, zero-token supervision** - a bash watcher sleeps on the fleet and wakes the first mate only when something needs you; verified primary harnesses also get a turn-end backstop that blocks or follows up on a blind stop when work is under way and supervision is not live.
- **Strict project boundary** - the first mate is read-only over your projects except for the narrow guarded and captain-approved operations authorized by [hard rule 1](AGENTS.md#1-identity-and-prime-directives), including fleet sync's guarded safe branch pruning; crewmates make every other project change behind the configured merge authority.
- **Restart-proof** - all state lives on disk and in the active session backend (tmux by hard default, herdr or cmux when selected or auto-detected, zellij/orca when explicitly selected); the next session reconciles durable work after a restart.

Full detail on every feature lives in [docs/architecture.md](docs/architecture.md).

## Quick Start

### Requirements

- A supported primary coding-agent harness and its own authenticated account when required.
- Node and Git, plus the tools for the chosen session backend; tmux is the reference default.
- Workflow-specific tools from the [toolchain requirements](docs/configuration.md#toolchain).

GitHub authentication is required for GitHub delivery; local-only delivery does not require it or the validation daemon.
An absent or unknown project delivery configuration keeps conservative prerequisites until a project mode is explicitly selected.
The first mate reports missing tools and asks before installing them.
Backend-specific setup is linked in [Documentation](#documentation).

### Recommended harnesses

**Claude Code, Grok, and Pi are equal co-primary recommendations** for running the primary firstmate session, with `pi-signed` supported as Pi's distinct signed-wrapper identity.
Claude Code uses a tracked Stop hook for tokenless watcher re-arm and rewake, Grok uses background-notify wake cycles, and Pi uses its tracked primary watcher extension.
All three have verified turn-end guard paths when launched with their documented setup.
Pick whichever one matches your subscription and workflow.

Oh My Pi (`omp`), a Pi fork, is verified as a primary with the same extension-owned watcher model as Pi and a stronger turn-end guard: its blocking `session_stop` hook compels a continuation instead of requesting one.
Codex and OpenCode are also verified and supported as primary harnesses; Codex uses bounded foreground checkpoints, and OpenCode uses a TUI plugin, so both carry more harness-specific supervision tradeoffs than the three co-primaries.
Cursor Agent CLI is verified as a primary too, using a tracked project-scope `.cursor/hooks.json` whose `stop` hook parks on the watcher between turns, closest in shape to Claude Code's.
Launch it with `--trust`, or none of its project hooks load; it also has no turn-end hook in headless `cursor-agent -p`, so run the primary session interactively.

### Install and launch

Obtain a reviewed Firstmate-lite checkout from the distribution source you selected.
Set `FIRSTMATE_LITE_URL` to that repository's actual clone URL before running:

```sh
git clone "$FIRSTMATE_LITE_URL" firstmate-lite
cd firstmate-lite
```

Alternatively, unpack a reviewed source archive into `firstmate-lite` and initialize it with `git init` and an initial commit before using Git-based workflows.
No separate build or package install step is required for the distro itself.
Keep operational records under the private home paths described in [configuration](docs/configuration.md); do not copy another operator's `data/`, `state/`, `config/`, `.env`, or `projects/` into a new installation.
For the tmux path, install its [backend prerequisites](docs/tmux-backend.md#setup) first.
Authenticate GitHub with `gh auth login` only when selecting a GitHub workflow.

Then launch a supported primary harness from the checkout; AGENTS.md takes over from there.
The harness support descriptions below are inherited integration guidance, subject to the derivative verification limits above:

**Claude Code**

```sh
claude
```

**Grok**

```sh
grok --trust
```

**Pi**

```sh
pi
# or, when the signed wrapper is installed
FM_PI_HARNESS=pi-signed pi-signed
```

**Oh My Pi**

```sh
omp
# or, when starting from inside a Claude Code pane
FM_OMP_HARNESS=omp omp
```

Start `omp` with this checkout as its working directory: it auto-discovers the tracked `.omp/extensions/*.ts` files with no trust dialog, and naming them with `-e` as well would load each twice.

For Grok, `--trust` is needed once per clone so project hooks and the turn-end guard load; `/hooks-trust` inside Grok works too.
For Pi, approve the project trust prompt once per clone on first launch so the tracked `.pi/extensions/*.ts` files auto-load.
The `/calm` toggle on Pi, and on Claude Code behind its default-off early-access function-hooks flag, hides supported transcript chrome, including canonically classified Firstmate operational user rows, and uses a Calm-only animated working boat during active runs while preserving all model context and session data.
Calm changes only presentation, not the user-role delivery, ordering, authority, persistence, or exports of the operational inputs it hides.
The preference persists for the effective Firstmate home, and toggling it off restores ordinary rendering.
[Calm's current behavior and supported limits](docs/calm.md) are separate from its [version-scoped maintainer evidence](docs/calm-mode-feasibility.md).
Pi's `/supervision-model` command pins a cheaper model and a shallower reasoning effort for the supervision branch alone, from the eligible models and thinking levels Pi itself reports, and with no pin the branch normally follows your own conversation's model and effort; see the [configuration schema](docs/configuration.md#pi-supervision-branch-model-and-effort-configsupervision-branch-model-configsupervision-branch-effort).

### Talk to it

```sh
> ahoy! look at my github project xyz, then fix the flaky login test and add dark mode

# firstmate checks its toolchain (asking your consent before installing anything),
# clones the project under projects/ and spawns two isolated workers in the active backend.
# Minutes later:

  PR ready for review, captain: https://github.com/you/xyz/pull/42
  (fix flaky login test - risk: low - CI green)

> alright merge it
```

### More backends

Setup guides for tmux (the default) and every other supported backend (herdr, zellij, Orca, cmux) are linked in [Documentation](#documentation) below.

## How It Works

```
            you (the captain)
                  │  chat: requests, decisions, "merge it"
                  ▼
 ┌─────────────────────────────────────┐
 │ firstmate            (this repo)    │
 │ reads projects/ + firstmate routes  │
 │ writes guarded backlog/briefs/state │
 └──┬──────────────┬───────────────┬───┘
    │ backend sends / status files │
    ▼              ▼               ▼
 ┌────────┐   ┌────────┐      ┌────────┐
 │fm-task1│   │fm-task2│  ... │fm-taskN│   tmux windows, herdr/zellij tabs, cmux workspaces, or Orca terminals
 │crewmate│   │crewmate│      │crewmate│   one autonomous agent each
 └───┬────┘   └───┬────┘      └───┬────┘
     ▼            ▼               ▼
  isolated task worktree
     │
     ├─ ship: project mode ► PR/local merge ► teardown
     │
     └─ scout: report at data/<id>/report.md ► decision inventory ► relay findings ► teardown
```

You chat with the first mate.
It routes each request to a crewmate in its own session endpoint and git worktree, supervises the fleet with a zero-token event-driven watcher, and brings you finished PRs, approved local merges, or investigation reports.
Dispatch profiles let you choose which harness handles each task.
`codex-app` is not a runtime backend yet; [docs/codex-app-backend.md](docs/codex-app-backend.md) owns the Codex App boundary.

Full architecture - the supervision engine, worktree isolation, dispatch profiles, project modes, fleet sync, and self-update - is in [docs/architecture.md](docs/architecture.md).

## Built-in skills

Firstmate ships these user-invocable built-in skills.
Claude and grok use the slash form shown here; codex uses the same names with `$`, such as `$afk`.

| Skill              | What it does                                                                                                                                  |
| ------------------ | -------------------------------------------------------------------------------------------------------------------------------------------- |
| `/afk`             | Enter away-mode supervision: Pi's in-process branch, a [supervision host](docs/configuration.md#supervision-host-configsupervision-host) beside the other primaries (on by default for Claude), or the daemon handles wakes while you step away; see the [away procedure](.agents/skills/afk/SKILL.md) for the posture and return contract |
| `/quiet`           | Keep routine wakes off main while staying and chatting; requested actions proceed now rather than waiting for your return. Where Pi's branch or an [attended supervision host](docs/supervision-host.md#quiet-mode) already does this, it only says so; otherwise it starts the quiet daemon, which stays active through ordinary chat until `/quiet off` |
| `/ahoy` | One bounded catch-up on current local work, relevant conversation continuity, and outstanding decisions; optional `detail`, `file`, `visual`/`lavish`, and `live`/`include PRs` modes add detail, artifacts, or network enrichment |
| `/bearings` | Transitional alias to `/ahoy`, with the same options and one output |
| `/updatefirstmate` | Guardedly fast-forward this home to the current upstream commit, then reread its instructions |
| `/stow` | File current knowledge and open records; Pi verifies the receipt and saves early before native compaction, with `save-only` available; see the [stow workflow](.agents/skills/stow/SKILL.md#pi-command-and-automatic-preservation) for scheduling limits |

Ahoy invocation examples (`/ahoy` remains an alias):

- `/ahoy` returns the fresh four-section digest in chat only.
- Owned-contribution follow-up comes from the cached coverage projection; `include PRs` remains the opt-in for repository-wide live PR enrichment.
- `/ahoy include PRs` keeps chat-only mode and opts into live PR enrichment.
- `/ahoy file` replaces today's `data/status-report-<YYYY-MM-DD>.md` from scratch and links it from the four-section chat digest.
- `/ahoy file include PRs` combines the dated report with live PR enrichment.

Agent-only reference skills live under `.agents/skills/` and are loaded by firstmate at the trigger points named in [`AGENTS.md`](AGENTS.md).

### Two-tier skill layout

Firstmate's skills live in two separate places with different audiences:

- `.agents/skills/` - agent-loaded skills (this section's table, plus firstmate's agent-only reference skills). Every one of these assumes a live firstmate home and is meaningless, or actively misleading, installed anywhere else, so each carries `metadata.internal: true` in its frontmatter. That flag hides them from installer discovery (tools like the [skills.sh](https://skills.sh) `npx skills add` installer) without affecting how firstmate itself loads them - frontmatter metadata is inert to the agent's own skill loader.
- `skills/` - public, installer-facing skills meant to be installed standalone into any project, independent of firstmate.
  Each one is a self-contained skill with no dependency on firstmate's paths, tools, or vocabulary.
  Today that is `skills/stow`, a generic session-knowledge-sweep skill that routes findings by explicit instruction first, then existing local conventions, then a private `.stow-notes.md` fallback, and curates tiered entries through decay, local archival, and user-approved on-demand offload proposals.
  It intentionally shares no code with the firstmate-internal `.agents/skills/stow` it is named after, so the two can evolve independently.

## Documentation

- [docs/architecture.md](docs/architecture.md) - maintainer architecture for the crew, supervision, worktrees, remote command transport, and project modes.
- [docs/configuration.md](docs/configuration.md) - environment variables, `FM_HOME`, runtime backend selection, trusted external process-event adapter setup, the files you set, and harness support.
- [docs/extension-bindings.md](docs/extension-bindings.md) - maintainer architecture for the narrow trusted external `process-event-adapter/1` package, binding, handshake, and evidence boundary.
- [docs/calm.md](docs/calm.md) - current `/calm` behavior on Pi and Claude Code and its supported presentation limits.
- [docs/fleet-ledger.md](docs/fleet-ledger.md) - the opt-in activity ledger outside tools can read to follow a home's tasks, and its record contract.
- [docs/wedge-alarm.md](docs/wedge-alarm.md) - configure the active alert for an away-mode escalation delivery that gets stuck.
- [docs/tmux-backend.md](docs/tmux-backend.md) - current setup and limits for the tmux reference backend.
- [docs/herdr-backend.md](docs/herdr-backend.md) - current setup, CI coverage, safety boundaries, and limits for the Herdr backend.
- [docs/zellij-backend.md](docs/zellij-backend.md) - current setup and limits for the experimental Zellij backend.
- [docs/orca-backend.md](docs/orca-backend.md) - current setup and limits for the experimental Orca backend.
- [docs/cmux-backend.md](docs/cmux-backend.md) - current setup, socket security, and limits for the experimental cmux backend.
- [docs/codex-app-backend.md](docs/codex-app-backend.md) - the current blocked Codex App backend boundary and rollout contract.
- [docs/verification/runtime-backends.md](docs/verification/runtime-backends.md) - active maintainer verification for runtime backend guarantees.
- [docs/turnend-guard.md](docs/turnend-guard.md) - the primary session's current "no turn ends blind" backstop, scope, loop safety, and compatibility limits.
- [docs/verification/supervision.md](docs/verification/supervision.md) - active maintainer verification for session-start, guard, continuity, and wedge integrations.
- [docs/supervision-protocols/](docs/supervision-protocols/) - rendered primary-harness watcher protocols for Claude, Codex, OpenCode, Pi and `pi-signed`, omp, Grok, Cursor, and unknown harness fallback.
- [docs/scripts.md](docs/scripts.md) - the `bin/` toolbelt reference.
- [docs/documentation-audiences.md](docs/documentation-audiences.md) - documentation audiences and the machine-checked placement boundary.
- [`AGENTS.md`](AGENTS.md) - the supervisor contract, role boundary, and routing index for conditional procedures.
- [CONTRIBUTING.md](CONTRIBUTING.md) - how to contribute, including the dev/test commands.

## Contributing

Contributions are welcome - see [CONTRIBUTING.md](CONTRIBUTING.md) for the workflow, repo conventions, and how to run the tests.

## License

MIT - see [LICENSE](LICENSE).
