# AGENTS.md — claude

A personal record of Claude Code usage and cost. The product is the documents,
not the code: there is no build and no test suite beyond the hook self-tests, and
a claim without a measurement is not worth much.

## Rules

- **Every number carries its source.** A figure comes from a transcript's `usage`
  or from a session's `cost-state`, and the document says which. Estimates are
  labelled as estimates and their assumption is stated.
- **A dated document is never rewritten.** `docs/reviews/` and `docs/changes/` are
  records: when something changes, a new document links to the old one.
- **Frontmatter is mandatory** for everything under `docs/`, except
  `docs/README.md` and `docs/templates/`. Links are relative.
- **No secrets.** No API keys, no paths holding credentials, no contents of
  `~/.claude/.credentials.json`. Local session IDs are fine.
- **Nothing is pushed** (`git push`) unless the owner asks.

## Layout

- `docs/reviews/` — measurements and audits, dated, immutable.
- `docs/plans/` — what is proposed, with phases and exit criteria.
- `docs/templates/` — the template for each type.
- `hooks/`, `settings/`, `agents/`, `skills/` — what `task install` applies.
- `scripts/` — the installer, the session audit and the hook self-tests.

## Checks

```bash
task lint   # bash -n on the hooks, py_compile on the scripts, jq on the JSON
task test   # 13 hook cases in a throwaway CLAUDE_CONFIG_DIR
task docs   # docs_lint.py over docs/
```

## Versions

- A release is a signed, annotated `vX.Y.Z` tag on a clean commit.
- Every release has its entry in `CHANGELOG.md`. A change that alters what
  `task install` writes, or what `task audit` reports, needs one.
- A published tag is never moved: if it is wrong, cut another release.
- `git push` and pushing tags stay with the owner.
