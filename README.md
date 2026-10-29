# claude

Usage and cost notes for Claude Code: what burns tokens, why, and which
configuration limits it. None of this is product code; it is the record of
measurements taken on real sessions and of the decisions that came out of them.

## Why it exists

Two seven-hour work sessions cost $66.83 and $28.50 without anything visibly
failing: the cache was working, the model was the same and the work was normal.
The difference between the two was one thing — six `fork` subagents that inherited
745k of context — and that is not visible in any panel. This repository keeps the
measurement and the guardrails so it does not happen blind again.

## Contents

| Document | What it is |
|---|---|
| [Session cost audit](docs/reviews/2026-10-28-claude-code-session-token-audit.md) | What was measured, what was ruled out, and where every dollar came from |
| [Guardrails plan](docs/plans/2026-10-28-claude-code-token-guardrails-plan.md) | Settings, hooks, skill, subagent and audit script, in phases |
| [Backlog](docs/backlog/claude.md) | Open work: Doing, Next, Later, Someday |
| [Changelog](CHANGELOG.md) | What each release changes in what `task install` writes or `task audit` reports |

## Method

Everything comes from the transcripts Claude Code writes to
`~/.claude/projects/<project>/<session>.jsonl`: every `assistant` record carries
the real API `usage`, and every session ends with a `cost-state` record holding
the total. The commands to reproduce it are in §9 of the audit.

## Configuration

The repository does not only document: it applies. `Taskfile.yml` installs the
guardrails into `~/.claude` idempotently, backing up `settings.json` first.

```bash
task              # list the tasks
task check        # what is applied and what is missing (read-only)
task install      # settings + hooks + agent + skill
task audit -- <session> [--cap 200000]
task test         # hook tests in a throwaway config dir
task lint         # bash -n on the hooks, py_compile on the scripts, jq on the JSON
task docs         # frontmatter and link checks over docs/
```

`task install` is idempotent: the `hooks` merge converges per event, replacing any
group that runs one of our commands and keeping foreign groups, so re-installing
after editing a hook updates it instead of stacking a second copy.

| Piece | Path in the repo | Destination |
|---|---|---|
| Settings | `settings/claude-{settings,hooks}.json` | `~/.claude/settings.json` (merge) |
| Hooks | `hooks/*.sh` | `~/.claude/hooks/` |
| Subagent | `agents/benchmark-runner.md` | `~/.claude/agents/` |
| Skill | `skills/benchmark-monitor/` | `~/.claude/skills/` |

### Hooks

| Hook | Event | What it does |
|---|---|---|
| `loop-concision.sh` | `UserPromptSubmit` | Keeps replies short on polls and automated reports |
| `cache-watch.sh` | `UserPromptSubmit` | Predicts an expired prompt cache (`last turn + TTL`); warns, and blocks the prompt above `CACHE_WATCH_BLOCK_USD` (default $0.50). Resending accepts the rebuild; `/clear` avoids it |
| `context-checkpoint.sh` | `PreToolUse` | Asks for confirmation once per threshold (200k, 400k, 600k, 800k; `CONTEXT_TIERS`) |
| `context-meter.sh` | `Stop` | Records the context numbers once per turn so the checkpoint never parses the transcript |
| `guard-deep-fork.sh` | `PreToolUse` | Denies a `fork` subagent when the session context is already deep |
| `guard-transcript-reads.sh` | `PreToolUse` | Stops reading raw task and session transcripts into the context |
| `guard-subagent-report.sh` | `SubagentStop` | Keeps a subagent's final report from dumping logs into the parent |
| `guard-model-switch.sh` | `PreModelSwitch` | Guards a model switch, which discards the prompt cache |

The decision to block or ask is only proven to reach the permission system in
headless mode; how an ACP client such as Zed draws it is still open (see the
backlog).

`task restore` rolls `settings.json` back to the last backup; `task uninstall`
removes the hooks, agent and skill and leaves the settings alone.

## Versions

Releases are signed, annotated `vX.Y.Z` tags on a clean commit, each with its
entry in [`CHANGELOG.md`](CHANGELOG.md). A published tag is never moved: a wrong
release is followed by another one. Current: `v0.4.1`.

## Conventions

`docs/` follows the `docs-architect` scheme: one folder per document type,
mandatory frontmatter, and the index in [`docs/README.md`](docs/README.md).
