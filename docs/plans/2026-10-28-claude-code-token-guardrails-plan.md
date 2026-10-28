---
status: draft
project: claude
date: 2026-10-28
related: [reviews/2026-10-28-claude-code-session-token-audit.md]
---

# Plan: context and cost guardrails for Claude Code sessions (2026-10-28)

## 1. Scope

**In.** Changes to the personal Claude Code configuration (`~/.claude/`), to the
`.claude/` of the repositories where the work happens and to their `AGENTS.md`,
that reduce the cost per session and make the two causes measured in
[the audit](../reviews/2026-10-28-claude-code-session-token-audit.md) impossible:
unbounded context and the forks that inherit it.

**Out.** The PLC agent, the benchmark, the `plc-prompts` pipeline and anything
that could move the result of a run. This plan does not change the behaviour of
the agent being evaluated; it changes how we work with Claude Code on top of it.
That is why it carries no `CHANGELOG.md` entry while it stays session tooling, and
would carry one if any piece ended up versioned as part of the repo.

## 2. The diagnosis behind each piece

| Measured cause | Evidence | Lever |
|---|---|---|
| Unbounded context (754k and 841k) | Native 1M window; auto-compact near 950k never fired | `autoCompactWindow` |
| Quadratic cost in turns | 440 requests, 167M reads in the main thread | window + `/clear` |
| Forks that inherit the context | 6 forks, $38.39 = 57% of the session | fork mode + guardrail |
| 5-minute TTL inside forks | 7 rebuilds of 787k every 10 min in `a642592f` | 1h TTL + cadence |
| Hooks injecting context | 272 KB of `hook_success`; 146 KB on `SessionStart:resume` | plugin audit |
| VM terminal pastes | 15 pastes, 157k chars, ~52k tokens | habit + skill |
| Thinking never cleared | 213,574 tokens with `keep: "all"` | not configurable; bound the turns instead |

The principle that orders the plan: **the closer to configuration and the further
from instructions, the stronger the guarantee and the lower the context cost.** A
`CLAUDE.md` asking for restraint is paid on every turn and enforces nothing; an
`autoCompactWindow` is paid once and always applies.

## 3. Proposals by tool type

### 3.1 Settings — priority 0

In `~/.claude/settings.json` (user scope: applies to every project).

```json
{
  "autoCompactWindow": 1000000,
  "promptCacheTtl": "1h",
  "subagentPromptCacheTtl": "1h",
  "env": { "CLAUDE_CODE_FORK_SUBAGENT": "0" }
}
```

| Key | Effect | Cost of the change |
|---|---|---|
| `autoCompactWindow: 1000000` | The model's own window is the ceiling | No cap in practice: the control is the checkpoint in §3.3.8 |
| `promptCacheTtl: "1h"` | Pins the main thread's TTL at 1 hour | Writes at 2x instead of 1.25x; with 1.39M of writes per session, negligible |
| `subagentPromptCacheTtl: "1h"` | Same for subagents, forks and compaction | Same; break-even on the second poll of a fork |
| `CLAUDE_CODE_FORK_SUBAGENT: "0"` | Claude stops opening forks on its own | `/subtask` still opens them by hand |

**The cap and the checkpoints are mutually exclusive controls.** A 200k cap holds
the context at 200k, so a confirmation at 400k could never fire. This plan ships
the checkpoint pair (§3.3.8) with the full window, so the context can grow where
the work needs it at a cost the user approves as it grows. If the priority is the
lowest possible bill instead of control, set the cap to `200000` and drop the
checkpoints: on the audited sessions that is ~$43 against $65 (an upper bound,
because a lower cap also shrinks the forks' rewrites).

Notes:

- Below 100k Claude Code ignores the value.
  A project that needs more overrides it per session with `/autocompact 750k` or
  `--autocompact`.
- All of this requires a build ≥ 2.1.296 (`autoCompactWindow`, `omitClaudeMd`) and
  ≥ 2.1.242 (the TTLs). Verified on 2.1.310.
- The alternative to turning fork mode off is to keep it and rely on the guardrail
  in §3.3.1. Turning it off is preferred: the guardrail protects against the
  expensive case, not against the unnecessary fork.

### 3.2 Permission rules — priority 0

```json
{
  "permissions": {
    "deny": [
      "Read(//tmp/claude-*/**)",
      "Read(//tmp/**/*.output)"
    ]
  }
}
```

**Scoped** rules: they do not change tool definitions and therefore do not
invalidate the cache prefix. A bare rule (`"Read"`) would.

### 3.3 Hooks — priority 1

Five guards, a two-hook context checkpoint pair, four optional ones and a list of
rejected ones. All of them are
`command` hooks with `jq`: no network, short `timeout`, because `PreToolUse` runs
on the critical path of every tool call (366 in the audited session).

The canonical scripts live in `hooks/*.sh` and `task install` applies them; the
snippets below show the shape and the decision of each. The difference matters in
one detail: the real scripts do not use `set -e`, because a failing
`(( condition )) && exit 0` ends the hook with code 1 and Claude Code reports it as
a hook error. They use explicit `if`s and close with `exit 0`.

#### 3.3.1 `guard-deep-fork.sh` — block forks with a deep parent

Why here and not in `SubagentStart`: that event **cannot block** subagent
creation. The only blocking point is `PreToolUse` on `Agent`.

```bash
#!/usr/bin/env bash
# PreToolUse · matcher: Agent
# Denies the fork when the session context already exceeds DEEP_FORK_LIMIT.
set -uo pipefail
input=$(cat)

# Only forks inherit the conversation. Explore, Plan and fresh subagents start
# with a clean context and cost the same at any depth.
subagent=$(jq -r '.tool_input.subagent_type // empty' <<<"$input")
[[ $subagent == "fork" ]] || exit 0

transcript=$(jq -r '.transcript_path // empty' <<<"$input")
[[ -z $transcript || ! -f $transcript ]] && exit 0

limit=${DEEP_FORK_LIMIT:-150000}
ctx=$(tail -n 4000 "$transcript" | grep -F '"type":"assistant"' | tail -n 20 | tac \
  | jq -r 'select(.message.usage)
      | .message.usage.input_tokens
      + .message.usage.cache_read_input_tokens
      + .message.usage.cache_creation_input_tokens' | head -1)

[[ $ctx =~ ^[0-9]+$ ]] || exit 0
(( ctx >= limit )) || exit 0

jq -n --argjson c "$ctx" --argjson l "$limit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      ("Context is " + ($c|tostring) + " tokens (limit " + ($l|tostring) + "). "
       + "Do not fork: a fork copies the history and re-sends it every turn. "
       + "Use a fresh subagent with a brief, or /clear first.")
  }
}'
exit 0
```

The check is narrowed to `subagent_type: "fork"`, the value the audited
transcripts use for every fork (verified across the six). Anything else —
`Explore`, `Plan`, `general-purpose`, a custom type — passes at any depth: those
start with a fresh context, so blocking them would lose capability without
saving anything. A call with no `subagent_type` passes too; Claude Code rejects
that call on its own grounds.

#### 3.3.2 `guard-transcript-reads.sh` — make the warning executable

```bash
#!/usr/bin/env bash
# PreToolUse · matcher: Read|Bash
set -uo pipefail
input=$(cat)
tool=$(jq -r '.tool_name' <<<"$input")
target=$(case $tool in
  Read) jq -r '.tool_input.file_path // empty' <<<"$input" ;;
  Bash) jq -r '.tool_input.command // empty' <<<"$input" ;;
esac)

transcript_re='\.output([^[:alnum:]]|$)|/tasks/[^/[:space:]]+$|/subagents/agent-[^/]*\.jsonl'
[[ $target =~ $transcript_re ]] || exit 0
[[ $tool == Bash ]] && ! [[ $target =~ (cat|tail|head|less|bat) ]] && exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      "Subagent transcript. Do not read it or tail it: use the agent's final report, a bounded grep, or the job's status file."
  }
}'
exit 0
```

#### 3.3.3 `guard-subagent-report.sh` — a verifiable output contract

```bash
#!/usr/bin/env bash
# SubagentStop · no matcher
set -uo pipefail
input=$(cat)
msg=$(jq -r '.last_assistant_message // empty' <<<"$input")
(( ${#msg} <= 4000 )) && exit 0

jq -n --argjson n "${#msg}" '{
  decision: "block",
  reason: ("The final report is " + ($n|tostring) + " characters. Compress it to a JSON of ≤20 lines with the metrics; detail goes to a file, not the message.")
}'
exit 0
```

`SubagentStop` with `decision: block` means "keep working", so the installed
script blocks **once per agent** (a marker under `.state/`) and lets the second
attempt through. Without that counter the subagent can loop.

#### 3.3.4 `loop-concision.sh` — short polls

```bash
#!/usr/bin/env bash
# UserPromptSubmit · no matcher
# Also fires on every /loop tick and every background subagent report.
set -uo pipefail
prompt=$(jq -r '.prompt // empty')
[[ $prompt =~ (task-notification|\[loop|scheduled) ]] || exit 0

jq -n '{hookSpecificOutput: {hookEventName: "UserPromptSubmit",
  additionalContext: "Poll or automated report: answer in ≤5 lines with the state. Do not repeat logs or the plan."}}'
exit 0
```

#### 3.3.5 `guard-model-switch.sh` — no upgrade with a deep context

It is not only Opus: **any** switch to a more expensive tier multiplies the
per-token cost, and **any** model switch, in either direction, discards the cache
prefix because every model has its own. So the guardrail compares tiers, not
names.

This event's input already carries what is needed (`from_model`, `to_model`,
`context_tokens`, `prompt_cache_warm`): the transcript never has to be read.

```bash
#!/usr/bin/env bash
# PreModelSwitch · no matcher (gateway models have no canonical name)
set -uo pipefail
input=$(cat)
from=$(jq -r '.from_model // ""' <<<"$input")
to=$(jq -r '.to_model // ""' <<<"$input")
ctx=$(jq -r '.context_tokens // 0' <<<"$input")
warm=$(jq -r '.prompt_cache_warm // false' <<<"$input")

tier() {
  case ${1,,} in
    *haiku*)  echo 1 ;;
    *sonnet*) echo 2 ;;
    *opus*)   echo 3 ;;
    *fable*|*mythos*) echo 4 ;;
    *)        echo 9 ;;   # unknown: treated as an upgrade
  esac
}

tf=$(tier "$from"); tt=$(tier "$to")

# Downgrades are allowed: they pay one rebuild and make every later turn cheaper.
(( tt < tf )) && exit 0
# Same tier: allowed (a hook cannot avoid the cache change anyway).
(( tt == tf )) && exit 0

limit=${DEEP_SWITCH_LIMIT:-150000}
(( ctx < limit )) && exit 0

jq -n --arg from "$from" --arg to "$to" --argjson ctx "$ctx" --argjson warm "$warm" '{
  hookSpecificOutput: {
    hookEventName: "PreModelSwitch",
    permissionDecision: "deny",
    permissionDecisionReason:
      ("Upgrade to a more expensive tier (" + $from + " → " + $to + ") with "
       + ($ctx|tostring) + " tokens of context and a "
       + (if $warm then "warm" else "cold" end) + " cache. Every turn costs more "
       + "and the whole prefix is re-sent. Finish the task or /clear first.")
  }
}'
exit 0
```

Verified notes about the event:

- `matcher` compares against the canonical name of the target model; an alias, a
  dated id and a provider id all match the same name. The real filter therefore
  lives in the script and the matcher is omitted: a custom gateway model makes
  Claude Code run **every** `PreModelSwitch` hook anyway.
- The hook **does not** run for switches Claude Code makes on its own, such as
  automatic fallback. That case is outside the guardrail.
- It can block with `permissionDecision: "deny"` or with `exit 2` and the reason on
  stderr.

Registration of the five in `~/.claude/settings.json`:

```json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "Bash|Read|Write|Edit|Agent", "hooks": [{ "type": "command", "command": "~/.claude/hooks/context-checkpoint.sh", "timeout": 5 }] },
      { "matcher": "Agent", "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-deep-fork.sh", "timeout": 5 }] },
      { "matcher": "Read|Bash", "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-transcript-reads.sh", "timeout": 5 }] }
    ],
    "Stop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/context-meter.sh", "timeout": 10 }] }
    ],
    "PreModelSwitch": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-model-switch.sh", "timeout": 5 }] }
    ],
    "SubagentStop": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/guard-subagent-report.sh", "timeout": 5 }] }
    ],
    "UserPromptSubmit": [
      { "hooks": [{ "type": "command", "command": "~/.claude/hooks/loop-concision.sh", "timeout": 5 }] }
    ]
  }
}
```

#### 3.3.6 Optional, with their trade-off

| Hook | What it would do | Why not by default |
|---|---|---|
| `PostToolUse` + `updatedToolOutput` | Trim every output to ~8k chars, keeping head and tail | Trimming blind hides the error you were looking for. Only with a command allowlist. |
| `PostToolBatch` | Measure tokens per batch and warn above 20k | Intervenes in the agent's judgement in the middle of a run; noisy if mis-tuned. |
| `PostCompact` | Log every compaction to a cost log | Telemetry only; useful to know whether the 200k ceiling is being touched. |
| `InstructionsLoaded` | Record which `CLAUDE.md` and `.claude/rules/*.md` load, and how much they weigh | Audit of the permanent prefix only. |

#### 3.3.7 Rejected, and why

| Event | Reason |
|---|---|
| `PreCompact` (`auto`) | Can block automatic compaction: the exact opposite of what is needed here. |
| `FileChanged` | Has no decision control and cannot inject context. "Let the job notify instead of polling" is not viable this way. |
| `SubagentStart` | `additionalContext` only, no blocking. |
| `MessageDisplay` | Changes what is displayed on screen, not what the model sees. |
| `prompt` or `agent` hook handlers | Cost tokens on every fire: counterproductive for saving tokens. |

#### 3.3.8 Context checkpoints — ask instead of capping

A hard cap and a confirmation cannot coexist: whichever is lower wins, and the
other never fires. The checkpoint pair replaces the cap as the primary control,
which is what makes a long context a decision instead of an accident.

- `context-meter.sh` (`Stop`, once per turn) parses the transcript tail and writes
  the current context to `hooks/.state/context-<session>`. This is the expensive
  half and it runs once per turn, not once per tool call.
- `context-checkpoint.sh` (`PreToolUse` on `Bash|Read|Write|Edit|Agent`) reads
  that small file and returns `permissionDecision: "ask"` the first time the
  context crosses each threshold. Defaults are **200k, 400k, 600k and 800k**;
  `CONTEXT_TIERS` overrides them.

The per-turn figure in the prompt is computed, not guessed:

```
cost/turn = (context - delta) * read_price + delta * write_price + output * out_price
```

The first two terms are the cache hit and the new content. Checked against the
two audited sessions it lands within **6%** of the observed cost per turn
(−6% on openhands-plc, +1% on openevolve), because `delta` (1.6k–2.3k per turn)
and `output` (0.9k–1.7k) are stable. What the formula cannot know is the cache
state, so the message also shows the rebuild price, which is 40x higher.

At Sonnet 5.5 prices with the 1h TTL the main thread actually uses
($4.00/M writes): 200k → $0.04/turn, 400k → $0.06, 600k → $0.08, 800k → $0.10,
against $1.01/2.01/3.01/4.01 for a rebuild at the same sizes.

Cost on the hot path: a file read plus one process per tool call, a few
milliseconds. The transcript parse stayed in the `Stop` hook. The arithmetic only
runs when a threshold is crossed. The user sees one prompt per threshold per
session, not one per tool call.

The marker is written **before** the answer is known, so a dismissal counts as
answered. Without that, every tool call above the threshold would prompt again.

Tested: 150k allows, 250k asks, 250k again does not, 450k asks again, 650k asks
at the 600k tier, the prompt carries a dollar figure, and the meter records both
the context and the delta.

#### 3.3.9 `cache-watch.sh` — warn before an expired cache is paid

Expiry is the one cost that can be predicted exactly. The cache lives for its TTL
counted from the last request that used it, and both the TTL and that request are
local, so `expiry = last turn + TTL` is arithmetic, not a guess.

`context-meter.sh` records the epoch of each turn. On `UserPromptSubmit`, before
the request goes out, `cache-watch.sh` compares it to now.

**A message alone would be theatre.** The hook runs before the request but does
not stop it: the warning would appear and the cold turn would go out anyway. So
above `CACHE_WATCH_BLOCK_USD` (default $0.50, roughly 125k of context at the 1h
write price) the prompt is **blocked once**, the user runs `/clear` or resends
deliberately, and the second attempt goes through. Below the threshold it only
warns, because refusing a $0.20 rebuild would be worse than paying it. The block
is keyed on the timestamp of the last turn, so one idle episode asks once and the
resend is never trapped in a loop.

At 412k and a 60-minute TTL, a 78-minute gap is a $1.65 rebuild — the same shape
as the single $2.95 event in the audited session, which nothing surfaced at the
time.

The cost is one event, not recurring: the cold turn rebuilds the prefix and the
following turns are warm again, which the message says explicitly.

What it cannot predict is an early eviction: the API may drop an entry before its
TTL under memory pressure. That residual risk is why the message says "about" and
why `audit-session-cost.py` still reconciles against `cost-state` afterwards.

### 3.4 `benchmark-monitor` skill — priority 1

A generic "token economy" skill never gets invoked. This one is task-shaped, so
it matches when the user says "follow the job's progress".

`.claude/skills/benchmark-monitor/SKILL.md`:

```markdown
---
name: benchmark-monitor
version: 1.0.0
description: Follow a running benchmark or long job without inflating the session context. Reads a bounded status file instead of logs, picks a safe poll cadence, and reports in five lines. Use when asked to watch progress, poll a job, or check whether a run finished.
---

# Benchmark monitor

## Rule

State lives in a file, not in the chat. The runner (not the agent) writes
`/tmp/<run>/status.json` with total, done, failed, current_trial, elapsed_s and
last_error. The agent reads that file with `jq -c` and never the full log.

## Procedure

1. Find the status file. If it does not exist, create it with the runner before
   starting; do not poll a log.
2. Read only what is needed: `jq -c '{done:([.trials[]|select(.status!="pending")]|length),
   total:(.trials|length), fails:[.trials[]|select(.status=="fail")|.id]}' status.json`
3. Report in ≤5 lines: total, done, failed, ETA, first suggested action.
4. Cadence: <5 min or >60 min, never in between. Prefer `/loop 5m` over a
   `sleep` in `Bash`, which occupies a whole turn.
5. Forbidden: `cat`/`tail`/`less` on `*.output`, JSONL transcripts or logs over
   200 lines. If detail is needed, a bounded `grep | head -20`.

## When done

One paragraph with the aggregate result and the artifact. Never dump the table of
N trials.
```

### 3.5 `benchmark-runner` subagent — priority 1

Replaces the fork for benchmark work: fresh context and an output contract.

`.claude/agents/benchmark-runner.md`:

```markdown
---
name: benchmark-runner
description: Runs PLC benchmark trials or long local jobs and returns aggregate metrics only. Use for benchmark runs, batch trials, or any task whose stdout is large.
tools: Bash, Read, Write
model: sonnet
effort: low
maxTurns: 40
autoCompactWindow: 100000
omitClaudeMd: true
isolation: worktree
experimental:
  cacheTtl: 1h
---

Never read JSONL transcripts or dump stdout. Write the detail to
/tmp/bench/<run>.log and return EXCLUSIVELY a JSON of ≤20 lines:
{"run","trials","passed","failed","duration_s","first_error"}.
On failure, return the same JSON with status:"error" and the first error.
Nothing else.
```

`autoCompactWindow` is 100000 because that is the minimum accepted; 50000 is
ignored silently.

### 3.6 `AGENTS.md` — priority 2

Only the judgement that cannot be automated. Three lines, not a paragraph:

```markdown
## Session cost

- Do not open a fork when the context is above 150k: delegate with a fresh subagent and a brief.
- Monitors read a status file; never dump logs or transcripts into the chat.
- When switching repository or task, `/clear`.
```

### 3.7 Observability — priority 0 (script) and 2 (OTel)

`scripts/audit-session-cost.py`: takes a session id, finds the JSONL and the
`subagents/`, and prints the audit table in one pass (per fork, per agent, reads,
writes, output, and the counterfactual at a given cap).

Interface:

```
$ scripts/audit-session-cost.py 01a5c123 --cap 200000
session     reqs      read     w5m     w1h      out   ctx_max     cost  cost@cap
main         440   166.03M       0   1.39M     397k      755k    26.12     13.73
agent-a642    48    31.83M   5.52M      38      34k      803k    17.34      4.45
...
TOTAL        701   344.53M   7.27M   1.40M     630k      803k    64.51     24.19
```

Also: the status line already shows `ctx remaining %`; adding cumulative cost
would make the live view complete. OTel is for when there are several machines:
it is the only thing that gives tokens per subagent in near real time.

### 3.8 `context-mode` plugin review — priority 1

`SessionStart:resume` injected **146,512 bytes** (~40k tokens) and
`PreToolUse:Agent` 65,277 bytes over 6 events. The script
`~/.claude/hooks/context-mode-cache-heal.mjs` is a self-heal, not the injector:
the content comes from the `context-mode@context-mode` plugin
(`~/.claude/context-mode/`).

Proposal: measure it for a week with the plugin off. If it is not missed, it stays
off. If it is, find which of its hooks emits the 146 KB and trim that one rather
than the whole plugin.

### 3.9 Habits — priority 2

1. `/clear` at every repository or task boundary. It is free and it is the biggest
   saving per unit of effort.
2. Do not paste VM terminal output into the chat: 15 pastes were ~52k permanent
   tokens. Alternatives: have the agent run the command, or write the output to a
   file and read a bounded range.
3. Polling: `<5 min` or `>60 min`. The 5–60 band is the worst possible case.

## 4. Phases

| Phase | What | Effort | Outcome |
|---|---|---|---|
| 0 | Settings from §3.1 and §3.2 + `audit-session-cost.py` | 30 min | Context ceiling and reproducible measurement |
| 1 | Hooks §3.3.1 and §3.3.2 | 45 min | Both expensive cases become impossible |
| 2 | Subagent §3.5 + skill §3.4 | 45 min | Benchmark work no longer needs forks |
| 3 | Hooks §3.3.3 to §3.3.5 + plugin audit §3.8 | 45 min | Output contract, short polls, plugin decided |
| 4 | `AGENTS.md` §3.6 + OTel if needed | 20 min | Explicit judgement and telemetry |

## 5. Exit criteria

- [ ] A six-hour session with both checkpoints declined ends below **$20**
      (baseline: $66.83). Accepting them is a deliberate choice and its cost is
      expected.
- [ ] No session opens a fork with the context above 150k.
- [ ] No read of a `*.output` or a transcript reaches the context.
- [ ] `audit-session-cost.py` reproduces the `cost-state` totals within 5%
      (the deduplication difference documented in the audit is ~3.5%).
- [ ] Starting a new session injects no more than ~10k tokens of hooks.
- [ ] Review at two weeks with the same commands as audit §9.

## 6. Estimated saving

| Piece | Saving | Overlaps with |
|---|---|---|
| `autoCompactWindow: 200000` | ~$22–25 | fork reads (they inherit less) |
| `subagentPromptCacheTtl: "1h"` | ~$12–14 | — |
| Not forking at depth | ~$16 on `a642592f`; up to $38 across the six | the window |
| Cadence `<5` or `>60` | ~$12 in the polling case | the 1h TTL (both avoid the same rebuild) |
| Fewer pastes and more `/clear` | ~$10–20 | the window |

With the checkpoints instead of the cap the saving is not automatic: it is what
the user buys by declining at 200k or at 400k. The figures below assume the cap
path.

They are not additive: the calculated counterfactual with the 200k ceiling leaves
the session at **~$32**, and removing the forks as well at **~$20–25**. Working
figure: **half to a third of the current bill**, without touching the model or the
quality of the work.

## 7. Risks

| Risk | Mitigation |
|---|---|
| A slow hook delays every tool call | Pure `jq`, no network, `timeout: 5`, narrow `matcher` |
| The fork guardrail blocks a legitimate case | The `deny` message explains the alternative; raise `DEEP_FORK_LIMIT` per session |
| Compacting at 200k loses useful context | `/compact Focus on …` before a boundary; raise the ceiling per project with `/autocompact` |
| A global `autoCompactWindow` affects projects that need more | Override per session with `--autocompact` or `/autocompact` |
| Trimming outputs (`PostToolUse`) hides errors | Not enabled by default; only on the allowlist in §3.3.6 |
| Overloading `AGENTS.md` | Three lines; the rest goes into hooks or settings |

## 8. Open questions

1. `CLAUDE_CODE_FORK_SUBAGENT=0` permanently, or only the depth guardrail? The
   first is cheaper and removes a decision from the agent; the second keeps the
   fork for cases where the history is genuinely needed.
2. `autoCompactWindow` global or per project? Global is simpler; per project
   respects repositories with legitimately long context.
3. Does the `context-mode` plugin earn its 40k tokens per resume?
4. Is OTel worth it now, or is `audit-session-cost.py` enough while there is a
   single machine?
