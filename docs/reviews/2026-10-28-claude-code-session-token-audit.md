---
status: done
project: claude
date: 2026-10-28
related: []
---

# Audit: why two Claude Code sessions cost $66.83 and $28.50 (2026-10-28)

Written 2026-10-28. Origin: the suspicion that a Claude Code session in
`automation-labs-openhands-plc` had consumed ~800,000 tokens "in 10 minutes"
through a log leak from a subagent. The suspicion was wrong about the mechanism
and about the time frame. This document records what was measured, what was
ruled out, and what is left to change.

"Read" means read from the transcript or the session's `cost-state`;
"calculated" means derived from those records; "estimated" means a projection
whose assumptions are stated. Nothing was changed in the environment during the
audit.

## 1. Method

Everything comes from the local transcripts Claude Code writes to
`~/.claude/projects/<project>/<session>.jsonl` and to the
`<session>/subagents/` subdirectory. Every `assistant` record carries the real
API `usage` (`input_tokens`, `cache_read_input_tokens`,
`cache_creation_input_tokens`, `output_tokens` and the `ephemeral_1h` /
`ephemeral_5m` split), and every session closes with a `cost-state` record that
declares the total.

Sessions audited:

| Session | Project | File |
|---|---|---|
| `01a5c123-d98d-4d1b-89b6-2241604af590` | `automation-labs-openhands-plc` | 7.0 MB, 2,862 lines |
| `bd4861f2-42da-470f-a8ba-c373f12875c5` | `automation-labs-openevolve` | 18 MB |

Environment read: Claude Code `2.1.310`, model `claude-sonnet-5-5` (native 1M
window), `querySource: sdk` (the ACP path from Zed), `effort: medium`.

## 2. The numbers

| | openhands-plc (main) | openhands-plc (6 forks) | openevolve |
|---|---|---|---|
| Requests | 440 | 265 | 353 |
| `cache_read` | 166.03M | 178.50M | 191.92M |
| 1h writes | 1.39M | 0.01M | 0.83M |
| 5m writes | 0 | **7.27M** | 0 |
| Output | 397k | 233k | 593k |
| Context min → max | 37,709 → 754,654 | 617k → **802,674** | 33,112 → **841,451** |
| Wall time | — | — | 7.3 h |
| **Cost** | **$26.12** | **$38.39** | **$28.50** |

`cost-state` for the `openhands-plc` session: **$66.83**, with 366,574,046 cache
read tokens, 8,751,538 cache creation tokens and 600,034 output tokens, over
7 h 21 min of wall time and 1 h 48 min of API time.

The costs in the table are recomputed per request and add up to $64.51 against
the $66.83 declared; the ~3.5% difference is the deduplication described in
§10. The proportions and the comparisons between objects hold.

Two observations order everything else:

1. **The two main conversations cost almost the same** (~$26–28, same shape).
   `openevolve` even reached a larger context (841k against 754k).
2. **The whole difference is the forks**: $38.39, 57% of the `openhands-plc`
   session.

The `openevolve` peak — the session people remember as "the hour that flew" — was
**18:00–19:00Z**: $6.50 over 68 requests at a 781k context, and inside that hour
the most expensive stretch was 18:10–18:20 (26 requests, 18.9M tokens read,
$1.89 in ten minutes). Nothing anomalous there: it is the same arithmetic as §3,
without forks to amplify it. The 15:00 hour of the same session cost $0.28 over
5 requests.

Breakdown of the expensive session (calculated):

| Component | Tokens | Price | Cost | % |
|---|---|---|---|---|
| Cache reads | 366.6M | $0.10/M | $36.66 | 55% |
| 5m writes (forks) | 7.27M | $2.50/M | $18.18 | 27% |
| 1h writes (main) | 1.39M | $4.00/M | $5.58 | 8% |
| Output | 0.60M | $10/M | $6.00 | 9% |

## 3. The mechanism: cost = Σ context

Every turn re-sends the whole context. The total cost is not
`context × turns` but the sum of the context over the turns, and because the
context grows with the turns, the result is quadratic in the length of the
session.

Context of the `openhands-plc` main thread, sampled every tenth of the session
(read):

```
req   1 (12:41)   37,709
req  89 (13:35)  176,070
req 177 (13:55)  269,546
req 265 (15:31)  440,188
req 353 (17:04)  605,846
req 440 (20:02)  754,654
```

The practical consequence: **one turn at 754k costs $0.075 — the same as a fresh
30-turn session from zero**. The cache discount (0.05x on Sonnet 5.5) is not a
substitute for bounding the context; it makes a number that was already large
cheaper.

Calculated counterfactual, recomputing every request with the context capped at
200k:

| | Actual reads | Capped at 200k | Factor |
|---|---|---|---|
| Main | 167.4M | 80.7M | 2.1x |
| Fork `a642592f` | 37.4M | 9.6M | 3.9x |
| Fork `abb9cae3` | 75.6M | 22.2M | 3.4x |
| Other forks | 72.8M | 20.4M | 3.5x |
| **Total** | **353.2M** | **132.9M** | **2.7x** |

Reads alone: $35.32 → $13.29. Including writes and output, the session would have
landed at ~$32 instead of $66.83.

## 4. Forks: what they are and which ones ran

A **fork** is a subagent that inherits the whole conversation — system prompt,
tools, model and history — instead of starting with a clean context. Its tool
calls stay out of the main thread, but **its context is a copy, not a reference**.
Fork mode is on by default: Claude can create forks on its own, and that is what
happened here (no `/subtask` was used).

`openevolve`: **zero forks**. There is no `subagents/` directory and there are 0
`Agent` calls across 353 requests (271 `Bash`, 16 `Read`).

`openhands-plc`: six forks, all `agentType: "fork"`, `model: inherit`.

| Fork | Start (Z) | End (Z) | Dur. | Req | Cost |
|---|---|---|---|---|---|
| `abb9cae3` | 16:40:17 | 17:03:54 | 24 min | 111 | $8.94 |
| `ae4e49d2` | 16:40:25 | 16:42:16 | 2 min | 11 | $0.90 |
| `a64f02a6` | 17:33:26 | 17:41:41 | 8 min | 26 | $2.05 |
| `a1e0eb66` | 17:48:04 | 18:29:09 | 41 min | 37 | $6.46 |
| `add42bf5` | 18:36:40 | 18:42:39 | 6 min | 28 | $2.67 |
| **`a642592f`** | **18:45:27** | **20:01:08** | **76 min** | **48** | **$17.34** |

The `a642592f` fork — the same `agentId` that appeared in the original alert —
cost 26% of the entire session in 76 minutes. Its first request read 745,037
tokens from the parent's cache: **it did not reach 800k by reading logs, it was
born at 745k** because the parent was already there. The 802,674 maximum is
inheritance plus its own work.

The rule that follows: a fork is proportional to the parent's context. With the
parent at 40k it is a shortcut; with the parent at 745k it is a second full
session on your bill. Practical threshold: **above ~150k, delegate to a fresh
subagent with an explicit brief, not to a fork**.

## 5. The 5-minute TTL: how much it explains

It explains $18 of the $67, all of it inside the forks. The main thread ran with
`ttl: "1h"` from the start and had **one** expiry-driven cache miss in seven
hours (the 76-minute gap between 18:45 and 20:01, which rewrote 736,876 tokens,
$2.95).

The TTL fingerprint, read from `a642592f`:

| Time | `cache_read` | `cache_creation` |
|---|---|---|
| 18:49:13 | 778,215 | 904 |
| 18:55:12 | 14,592 | 765,120 |
| 19:01:38 | 14,592 | 766,331 |
| 19:07:37 | 800,378 | 598 |
| 19:17:33 | 14,592 | 786,796 |
| 19:27:32 | 14,592 | 787,117 |
| 19:37:28 | 14,592 | 787,438 |
| 19:47:32 | 14,592 | 787,759 |
| 19:57:32 | 14,592 | 788,080 |

Exactly ten-minute spacing, a five-minute TTL, 787k rewritten on every fire. The
general rule: **any interval between the TTL and twice the TTL is the worst
possible case** — it guarantees the miss without amortising the one-hour write.
Either under 5 minutes (`/loop 5m` fires at 4m45s on purpose) or over 60.

## 6. What was ruled out

| Hypothesis | Verdict | Evidence |
|---|---|---|
| The subagent JSONL leaked into the main thread through ACP | **False** | One `Read` call in seven hours against 366 `Bash` calls; the four commands that touched a `.output` were `cat … \| tail -3 \| cut -c-200`. ACP does not carry model traffic. |
| The ACP proxy absorbed the subagent's output | **False** | The process talks to the API directly (`querySource: sdk`, its own `cacheControl`). |
| Environment mutation invalidated the cache prefix | **False** | 440 of 440 main-thread requests had `cache_read > 0`: zero misses. Editing files does not invalidate the prefix; only what sits before the breakpoint does. |
| The 10-minute loop drove the main thread's consumption | **False in the main thread, true in one fork** | The main thread had no loop; the 10-minute pattern appears only inside `a642592f`, from 18:55 to 19:57. |
| 14 trials in parallel | **False** | Six forks in five waves (two overlapping at 16:40) and ~9 background `Bash` tasks. |

## 7. Where the 754k of context came from

Measured composition (characters → approximate tokens):

| Component | Measure | ~Tokens |
|---|---|---|
| Retained thinking | 213,574 declared in `cost-state` | 213,574 |
| `Bash` output | 553,353 chars / 366 calls | ~150,000 |
| Hooks | 272,000 chars / 77 events | ~80,000 |
| System prompt, tools, skills, CLAUDE.md | — | ~90,000 |
| Manual user pastes | 156,932 chars / 15 pastes | ~52,000 |
| Assistant text and tool inputs | 97,000 chars | ~28,000 |

Two details that do not show up when reading the transcript casually:

- The 420 thinking blocks are stored with `"thinking": ""` and only the
  `signature`. The text is not there, but it is in the context: every request
  carries
  `context_management: {"edits": [{"type": "clear_thinking_20251015", "keep": "all"}]}`.
  It is never cleared, which makes it the largest single contributor and
  invisible to a character-based audit.
- The largest single-turn jump in seven hours was **+22,089 tokens** (2.9% of the
  total), and it was a 46,087-character paste of a VM terminal transcript. There
  was no spike: there was an integral.

Hooks that injected context into the main thread: `PreToolUse:Agent` 65,277 bytes
over 6 events, `Stop` 20,637 bytes over 67 events, `SessionStart:startup` 5,247
bytes. A `SessionStart:resume` hook of **146,512 bytes** also fired at the end:
resuming that session would inject ~40k tokens into a context already at 750k.

## 8. Recommendations

Ordered by estimated saving, with the effect calculated on this session:

1. **`autoCompactWindow: 200000`** — saves ~$22–25. The biggest lever: it bounds
   the main thread's reads and, in cascade, the context every fork inherits. The
   default on a 1M model compacts near 950k, so the protection existed and never
   triggered.
2. **`subagentPromptCacheTtl: "1h"`** — saves ~$12–14. Turns the ~10 rebuilds of
   787k into one write plus reads. Break-even on the second poll. The equivalent
   key in an agent's frontmatter is `experimental.cacheTtl: 1h`.
3. **Do not fork with a deep parent** — saves ~$16 on `a642592f` alone. Above
   ~150k of parent context, delegate to a fresh subagent.
4. **Poll interval: never between 5 and 60 minutes.** Under 5 or over 60.
5. **Audit the hooks**: 272 KB of `hook_success` is as much text as the 366
   `Bash` calls combined, and once injected it is permanent.
6. **Drop `.claudeignore`**: it does not exist in Claude Code. To block paths,
   use `permissions.deny` with scoped rules (`Read(//tmp/claude-*/**)`), which do
   not invalidate the prefix; a bare rule (`"Read"`) does.

All of these keys require a build ≥ 2.1.296 and exist in 2.1.310, so there is no
risk of them being ignored silently.

## 9. How to repeat the measurement

The authoritative total for a session:

```bash
jq -c 'select(.type=="cost-state") | {totalCostUSD, modelUsage}' <session>.jsonl
```

The per-request profile, which separates volume from cache misses:

```bash
jq -r 'select(.type=="assistant" and .message.usage!=null)
  | [.timestamp, .message.id,
     .message.usage.cache_read_input_tokens,
     .message.usage.cache_creation_input_tokens,
     .message.usage.output_tokens] | @tsv' <session>.jsonl \
| awk '!seen[$2]++'
```

Reading the signatures:

- `cache_creation` ≈ the context size and `cache_read` ≈ 14k, repeating every N
  minutes → TTL expiry.
- `cache_read` ≈ the context size, sustained → healthy cache, spend driven by
  volume.
- A context jump of tens of thousands in one turn → injected content (a paste, a
  hook, a file read), not accumulation.

Forks are measured separately, in `<session>/subagents/agent-*.jsonl`, with the
same command. `cost-state` **does not** break the total down per fork: the
`subagents/` transcripts have to be summed.

## 10. Limits of this analysis

- Totals come from `cost-state`; the per-hour and per-fork splits are recomputed
  and undercount by ~3.5% (openhands-plc) and ~14% (openevolve) against the
  total, because partial streaming writes are deduplicated. The proportions hold;
  the official totals govern.
- Thinking is redacted in the transcript (`thinking: ""` plus a `signature`), so
  its weight is taken from `cost-state` rather than measured in characters.
- This was not reconciled against an Anthropic invoice. The prices used are
  Sonnet 5.5 list prices: $2/M base, $0.10/M cache read (0.05x), $2.50/M 5m write
  (1.25x), $4/M 1h write (2x), $10/M output.
- `advisorModel: claude-opus-5-5` appears in the records; it could not be
  isolated whether it produced additional billable requests outside the
  `modelUsage` read.
