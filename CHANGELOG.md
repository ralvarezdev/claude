# Changelog

All notable changes to this repository. Format based on
[Keep a Changelog](https://keepachangelog.com/en/1.1.0/); versioning follows
[Semantic Versioning](https://semver.org/spec/v2.0.0.html).

This repository has no runtime: a release marks a state of the documentation and
the tooling that applies it. Anything that changes what `task install` writes to
`~/.claude`, or what `task audit` reports, is a change worth an entry.

## [Unreleased]

### Fixed

- `guard-deep-fork.sh` now denies only `subagent_type: "fork"`. It used to deny
  every `Agent` call above the limit, which would also have blocked `Explore`,
  `Plan` and fresh subagents at depth even though those start with a clean
  context and cost the same there. Self-tests cover the four combinations.

### Changed

- Translated the whole repository to English: the audit, the plan, the hook
  messages, the script output, the Taskfile descriptions, the subagent and the
  skill. Figures, findings and decisions are unchanged; only the language is.
- The audit and the plan were translated in place rather than reissued as new
  dated documents. That is the one exception to the "a dated document is never
  rewritten" rule, and it is called out here so it stays legible.

### Notes

- `task check` compares installed files byte for byte, so an existing
  installation reports `MISS` for every hook and script until `task install`
  runs again.

## [0.2.0] - 2026-10-28

The guardrails stop being a proposal and become something that runs.

### Added

- `Taskfile.yml`: `check`, `verify`, `install` (and its `settings`, `hooks`,
  `agent`, `skill` subtasks), `install:dry`, `uninstall`, `restore`, `audit`,
  `sessions`, `test`, `lint`, `docs`.
- Five hooks in `hooks/`, installed to `~/.claude/hooks/`:
  - `guard-deep-fork.sh` (`PreToolUse` on `Agent`) denies a fork once the session
    context passes 150k. `SubagentStart` cannot block creation, so this is the
    only place the check can live.
  - `guard-transcript-reads.sh` (`PreToolUse` on `Read|Bash`) denies reading or
    dumping `*.output` and agent transcripts, and allows a bounded `grep`.
  - `guard-subagent-report.sh` (`SubagentStop`) rejects a final report over 4000
    characters, once per agent. The counter is required: a block on
    `SubagentStop` means "keep working".
  - `loop-concision.sh` (`UserPromptSubmit`) detects loop ticks and background
    notifications and asks for a five-line answer.
  - `guard-model-switch.sh` (`PreModelSwitch`) denies a switch to a more
    expensive model tier when the context is deep, and allows downgrades.
- `scripts/apply-settings.py`: idempotent deep merge into
  `~/.claude/settings.json`, with a timestamped backup, `--dry-run`, `--check`
  and `--restore`. Objects merge by key, arrays are unioned, existing keys
  survive.
- `scripts/audit-session-cost.py`: per-agent tokens, cost and context for one
  session, the sum of context over requests, a `--cap` projection, and the
  session's own `cost-state` printed next to the reconstruction. Rebuilds
  $64.51 against $66.83 declared (-3.5%) and $25.46 against $28.50 (-10.6%).
- `scripts/selftest.sh`: 13 cases that feed each hook the JSON Claude Code sends
  and assert the decision, in a throwaway `CLAUDE_CONFIG_DIR`.
- `settings/claude-settings.json` and `settings/claude-hooks.json`: the keys to
  merge, with `__HOME__` resolved at install time.
- `agents/benchmark-runner.md`: subagent with a JSON output contract,
  `autoCompactWindow: 100000`, `omitClaudeMd` and `maxTurns`.
- `skills/benchmark-monitor/SKILL.md`: poll a job from a status file, never from
  a log, at `<5` or `>60` minute intervals.
- A "Configuración" section in the README, and a note in the plan recording why
  the hooks do not use `set -e` and where `PreModelSwitch` does not fire.

### Notes

- Nothing was applied to a live configuration by this release; `task install`
  does that, and `task uninstall` reverses it without touching `settings.json`.

## [0.1.0] - 2026-10-28

First published state: the measurement and the plan that follows from it.

### Added

- `docs/reviews/2026-10-28-claude-code-session-token-audit.md`: why two
  seven-hour sessions cost $66.83 and $28.50. Establishes that there was no log
  leak (one `Read` call against 366 `Bash` calls), no cache pathology in the main
  thread (440 of 440 requests hit), and that the forks — 57% of the bill —
  inherited the context instead of growing into it. Includes the 200k
  counterfactual (353M to 133M reads, 2.7x) and the commands to reproduce it.
- `docs/plans/2026-10-28-claude-code-token-guardrails-plan.md`: five phases with
  measurable exit criteria, savings per piece with their overlaps declared, risks
  and open questions.
- `README.md`, `AGENTS.md`, `docs/README.md` and the `review`/`plan` templates.
- rsk project with `repo-tooling-architect` installed but deliberately not
  pinned: pinning it would put its 18.6 KB (~4.5k tokens) in the prefix of every
  request, which is the problem this repository documents.
