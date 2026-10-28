# claude

Open work on the session cost guardrails, the audit tooling and the repository
itself. Everything here comes from
[the audit](../reviews/2026-10-28-claude-code-session-token-audit.md) or
[the plan](../plans/2026-10-28-claude-code-token-guardrails-plan.md).

## Doing

- [ ] Verify the `ask` prompt end to end in Zed, then re-measure one session  #claude  P1
  origin: [plan](../plans/2026-10-28-claude-code-token-guardrails-plan.md)
  Only the headless path is proven: `permissionDecision: "ask"` degrades to a
  denial in `claude -p`. Whether the ACP adapter in Zed renders it as a dialog is
  untested, and it is the whole premise of the checkpoint design.
  Done when: a real session crosses 200k, the prompt appears, one threshold is
  accepted and the next declined, and `task audit` reports that session below the
  $0.0546 per turn of the reference sessions.

- [ ] Decide what a dismissed prompt means  #claude  P1
  origin: [plan](../plans/2026-10-28-claude-code-token-guardrails-plan.md)
  The marker is written before the answer is known, so `Esc` counts as consent
  for the rest of the session and the guardrail disappears silently. The
  alternatives are re-asking every N turns, treating a dismissal as a `deny`, or
  leaving it and documenting it.
  Done when: the behaviour is written in the plan and covered by a self-test.

## Next

- [ ] Stop denying tools in headless runs that cross a threshold  #claude  P1
  origin: [plan](../plans/2026-10-28-claude-code-token-guardrails-plan.md)
  In `claude -p` there is no one to ask, so the checkpoint blocks the tool. Any
  long automation now fails at 200k. Options: skip the hook when
  `permission_mode` is non-interactive, raise `CONTEXT_TIERS` for those runs, or
  fall back to `additionalContext` instead of `ask`.

- [ ] Decide the fate of the `context-mode` plugin  #claude  P2
  origin: [audit §7](../reviews/2026-10-28-claude-code-session-token-audit.md)
  Its `SessionStart:resume` hook injected 146,512 bytes (~40k tokens) and
  `PreToolUse:Agent` 65,277 bytes over 6 events. Measure a week with it off, then
  either leave it off or trim the hook that emits the 146 KB.

- [ ] Measure the hooks' latency in a real session  #claude  P2
  origin: [plan §3.3.8](../plans/2026-10-28-claude-code-token-guardrails-plan.md)
  Three `PreToolUse` hooks on `Bash` means three processes per call, 366 calls in
  the audited session. The estimate is 3–5 ms each, never timed.

- [ ] Reconcile the plan's status  #claude  P3
  origin: [plan](../plans/2026-10-28-claude-code-token-guardrails-plan.md)
  It is `draft` while most of it is implemented and released as 0.3.0. Either
  promote it and record the open phases, or split the unimplemented parts into a
  new draft.

- [ ] Point `automation-labs-openhands-plc` at this repository  #claude  P3
  origin: [audit](../reviews/2026-10-28-claude-code-session-token-audit.md)
  The audit and the plan were moved here and their index rows removed there.
  Nobody reading that repository's docs will find this work.

## Later

- [ ] Recover a guaranteed saving with `autoCompactWindow: 400000`  #claude  P2
  origin: [plan §3.1](../plans/2026-10-28-claude-code-token-guardrails-plan.md)
  The checkpoints made the saving conditional on saying no. A 400k cap would turn
  the second threshold into a ceiling and keep the 200k question.

- [ ] Export OTel  #claude  P3
  origin: [plan §3.7](../plans/2026-10-28-claude-code-token-guardrails-plan.md)
  Only worth it with more than one machine. It is the only path to tokens per
  subagent in near real time.

## Someday

- [ ] A `task release` like the PLC repos: bump the changelog, commit, sign the
  tag, push. Right now it is four manual steps.
- [ ] Make the repository public once the session IDs and project names in the
  audit feel safe to publish.
