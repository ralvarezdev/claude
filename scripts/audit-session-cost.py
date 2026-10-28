#!/usr/bin/env python3
"""Cost and context audit for one Claude Code session.

Reads the session transcript and its subagent transcripts from
$CLAUDE_CONFIG_DIR/projects (default ~/.claude/projects), then prints tokens,
cost and the context each request re-sent. The session's own `cost-state`
record is printed alongside as the reference total, so the difference between
what the transcript records and what was actually billed stays visible.

Usage:
    audit-session-cost.py [SESSION_ID] [--cap TOKENS] [--json] [--list]

With no SESSION_ID, the most recently modified session on the machine is used.
Only the standard library is used so the script runs anywhere Python 3.11 does.
"""

from __future__ import annotations

import argparse
import json
import os
import sys
from collections import defaultdict
from dataclasses import dataclass, field
from datetime import datetime
from pathlib import Path

# (base input, cache read, 5m cache write, 1h cache write, output) in USD per MTok.
# Cache read is not always 0.1x: Opus 5.5 and Sonnet 5.5 bill it at 0.05x.
PRICES = {
    "claude-sonnet-5-5": (2.00, 0.10, 2.50, 4.00, 10.00),
    "claude-sonnet-5": (2.00, 0.20, 2.50, 4.00, 10.00),
    "claude-sonnet-4-6": (3.00, 0.30, 3.75, 6.00, 15.00),
    "claude-sonnet-4-5": (3.00, 0.30, 3.75, 6.00, 15.00),
    "claude-opus-5-5": (4.00, 0.20, 5.00, 8.00, 20.00),
    "claude-opus-5": (5.00, 0.50, 6.25, 10.00, 25.00),
    "claude-opus-4-8": (5.00, 0.50, 6.25, 10.00, 25.00),
    "claude-opus-4-7": (5.00, 0.50, 6.25, 10.00, 25.00),
    "claude-opus-4-6": (5.00, 0.50, 6.25, 10.00, 25.00),
    "claude-opus-4-5": (5.00, 0.50, 6.25, 10.00, 25.00),
    "claude-haiku-5-5": (0.10, 0.01, 0.125, 0.20, 0.50),
    "claude-haiku-4-5": (1.00, 0.10, 1.25, 2.00, 5.00),
}

FAMILY_FALLBACK = {
    "sonnet": "claude-sonnet-4-6",
    "opus": "claude-opus-4-6",
    "haiku": "claude-haiku-4-5",
}


@dataclass
class Bucket:
    """Accumulated usage for one transcript (the main conversation or one agent)."""

    name: str
    kind: str = "main"
    requests: int = 0
    read: int = 0
    write_5m: int = 0
    write_1h: int = 0
    output: int = 0
    ctx_max: int = 0
    ctx_sum: int = 0
    models: set[str] = field(default_factory=set)
    first_ts: str = ""
    last_ts: str = ""

    def add(self, usage: dict, model: str, ts: str) -> None:
        read = usage.get("cache_read_input_tokens") or 0
        creation = usage.get("cache_creation") or {}
        w5 = creation.get("ephemeral_5m_input_tokens") or 0
        w1 = creation.get("ephemeral_1h_input_tokens") or 0
        if not w5 and not w1:
            w1 = usage.get("cache_creation_input_tokens") or 0
        ctx = (usage.get("input_tokens") or 0) + read + w5 + w1
        self.requests += 1
        self.read += read
        self.write_5m += w5
        self.write_1h += w1
        self.output += usage.get("output_tokens") or 0
        self.ctx_max = max(self.ctx_max, ctx)
        self.ctx_sum += ctx
        self.models.add(model)
        self.first_ts = self.first_ts or ts
        self.last_ts = ts

    def price(self) -> tuple[float, float, float, float, float]:
        for model in sorted(self.models, key=len, reverse=True):
            for candidate, table in PRICES.items():
                if model.startswith(candidate):
                    return table
        for family, fallback in FAMILY_FALLBACK.items():
            if any(family in m for m in self.models):
                return PRICES[fallback]
        return PRICES["claude-sonnet-4-6"]

    def cost(self) -> float:
        base, read_p, w5_p, w1_p, out_p = self.price()
        return (
            self.read * read_p
            + self.write_5m * w5_p
            + self.write_1h * w1_p
            + self.output * out_p
        ) / 1_000_000

    def capped_ctx(self, cap: int) -> int:
        return self.ctx_sum if cap <= 0 else min(self.ctx_sum, cap * self.requests)


def config_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    if env:
        return Path(env).expanduser()
    return Path.home() / ".claude"


def find_session(session_id: str | None) -> tuple[str, Path, list[Path]]:
    """Return (session_id, transcript, subagent_transcripts)."""
    projects = config_dir() / "projects"
    if not projects.is_dir():
        sys.exit(f"no transcripts under {projects}")

    candidates = sorted(projects.glob("*/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
    if session_id:
        candidates = [p for p in candidates if p.stem == session_id]
        if not candidates:
            sys.exit(f"session {session_id} not found under {projects}")

    transcript = candidates[0]
    subagents = sorted((transcript.parent / transcript.stem / "subagents").glob("agent-*.jsonl"))
    return transcript.stem, transcript, subagents


def read_transcript(path: Path, name: str, kind: str) -> Bucket:
    bucket = Bucket(name=name, kind=kind)
    seen: set[str] = set()
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if not line.strip():
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("type") != "assistant":
                continue
            message = record.get("message") or {}
            usage = message.get("usage")
            if not usage:
                continue
            message_id = message.get("id")
            if message_id:
                # Streaming writes the same message more than once with identical usage.
                if message_id in seen:
                    continue
                seen.add(message_id)
            bucket.add(usage, message.get("model") or "?", record.get("timestamp") or "")
    return bucket


def read_cost_state(path: Path) -> dict | None:
    state = None
    with path.open(encoding="utf-8", errors="replace") as handle:
        for line in handle:
            if '"cost-state"' not in line:
                continue
            try:
                record = json.loads(line)
            except json.JSONDecodeError:
                continue
            if record.get("type") == "cost-state":
                state = record
    return state


def human(tokens: int) -> str:
    if abs(tokens) >= 1_000_000:
        return f"{tokens / 1_000_000:.2f}M"
    if abs(tokens) >= 1_000:
        return f"{tokens / 1_000:.0f}k"
    return str(tokens)


def render(buckets: list[Bucket], cap: int, session: str, cost_state: dict | None) -> None:
    header = f"{'agent':<26}{'reqs':>6}{'read':>10}{'w5m':>9}{'w1h':>9}{'out':>9}{'ctx_max':>10}{'cost':>9}"
    if cap:
        header += f"{'cost@cap':>9}"
    print(f"session {session}")
    print(header)
    print("-" * len(header))

    totals = Bucket(name="TOTAL")
    for bucket in buckets:
        totals.requests += bucket.requests
        totals.read += bucket.read
        totals.write_5m += bucket.write_5m
        totals.write_1h += bucket.write_1h
        totals.output += bucket.output
        totals.ctx_max = max(totals.ctx_max, bucket.ctx_max)
        totals.ctx_sum += bucket.ctx_sum
        totals.models |= bucket.models
        row = (
            f"{bucket.name[:25]:<26}{bucket.requests:>6}{human(bucket.read):>10}"
            f"{human(bucket.write_5m):>9}{human(bucket.write_1h):>9}"
            f"{human(bucket.output):>9}{human(bucket.ctx_max):>10}{bucket.cost():>9.2f}"
        )
        if cap:
            row += f"{bucket.capped_ctx(cap) and bucket.cost() * bucket.capped_ctx(cap) / max(bucket.ctx_sum, 1):>9.2f}"
        print(row)

    print("-" * len(header))
    row = (
        f"{'TOTAL':<26}{totals.requests:>6}{human(totals.read):>10}"
        f"{human(totals.write_5m):>9}{human(totals.write_1h):>9}"
        f"{human(totals.output):>9}{human(totals.ctx_max):>10}{totals.cost():>9.2f}"
    )
    if cap:
        projected = sum(
            b.cost() * b.capped_ctx(cap) / max(b.ctx_sum, 1) for b in buckets
        )
        row += f"{projected:>9.2f}"
    print(row)

    print()
    if cap:
        print(f"cost@cap: projection scaling cost by the ratio of the capped context "
              f"({human(cap)}) to the real one. Assumes writes and output are unchanged; "
              "an upper bound, not an invoice.")
    print(f"context per request: mean {human(totals.ctx_sum // max(totals.requests, 1))}, "
          f"max {human(totals.ctx_max)}")
    print(f"total re-sent (sum of context): {totals.ctx_sum:,} tokens")

    if cost_state:
        declared = cost_state.get("totalCostUSD") or 0
        print(f"cost-state declares ${declared:.2f}; this report reconstructs ${totals.cost():.2f}")
        delta = totals.cost() - declared
        pct = (delta / declared * 100) if declared else 0
        print(f"difference: ${delta:+.2f} ({pct:+.1f}%). "
              "A growing difference points to billed requests with no record in the transcript.")


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("session", nargs="?", help="session id (default: most recent)")
    parser.add_argument("--cap", type=int, default=0, metavar="TOKENS",
                        help="recompute as if every request were capped at this context")
    parser.add_argument("--json", action="store_true", help="machine-readable output")
    parser.add_argument("--list", action="store_true", help="list recent sessions and exit")
    args = parser.parse_args()

    if args.list:
        projects = config_dir() / "projects"
        sessions = sorted(projects.glob("*/*.jsonl"), key=lambda p: p.stat().st_mtime, reverse=True)
        for path in sessions[:20]:
            when = datetime.fromtimestamp(path.stat().st_mtime).strftime("%Y-%m-%d %H:%M")
            print(f"{path.stem}  {when}  {path.parent.name}")
        return

    session, transcript, subagents = find_session(args.session)
    buckets = [read_transcript(transcript, "main", "main")]
    buckets += [read_transcript(path, path.stem, "subagent") for path in subagents]
    cost_state = read_cost_state(transcript)

    if args.json:
        print(json.dumps(
            {
                "session": session,
                "cap": args.cap,
                "agents": [
                    {
                        "name": b.name,
                        "kind": b.kind,
                        "requests": b.requests,
                        "read": b.read,
                        "write_5m": b.write_5m,
                        "write_1h": b.write_1h,
                        "output": b.output,
                        "ctx_max": b.ctx_max,
                        "cost_usd": round(b.cost(), 4),
                    }
                    for b in buckets
                ],
                "declared_cost_usd": (cost_state or {}).get("totalCostUSD"),
            },
            indent=2,
        ))
        return

    render(buckets, args.cap, session, cost_state)


if __name__ == "__main__":
    main()
