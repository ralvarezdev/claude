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
```

| Piece | Path in the repo | Destination |
|---|---|---|
| Settings | `settings/claude-{settings,hooks}.json` | `~/.claude/settings.json` (merge) |
| Hooks | `hooks/*.sh` | `~/.claude/hooks/` |
| Subagent | `agents/benchmark-runner.md` | `~/.claude/agents/` |
| Skill | `skills/benchmark-monitor/` | `~/.claude/skills/` |

`task restore` rolls `settings.json` back to the last backup; `task uninstall`
removes the hooks, agent and skill and leaves the settings alone.

## Conventions

`docs/` follows the `docs-architect` scheme: one folder per document type,
mandatory frontmatter, and the index in [`docs/README.md`](docs/README.md).
