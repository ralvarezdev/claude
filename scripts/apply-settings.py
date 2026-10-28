#!/usr/bin/env python3
"""Merge this repository's Claude Code settings into ~/.claude/settings.json.

The repository owns a set of keys (settings/claude-settings.json) and a hooks
block (settings/claude-hooks.json). This script merges them into the live file
without touching anything else: objects merge key by key, arrays are unioned, and
scalars from the repository win.

Every write is preceded by a timestamped backup. Re-running is idempotent.

Usage:
    apply-settings.py --dry-run   show the merged result, write nothing
    apply-settings.py --check     exit 1 if any key from the repository is missing
    apply-settings.py --restore   restore the most recent backup
    apply-settings.py             apply the merge
"""

from __future__ import annotations

import argparse
import json
import os
import shutil
import sys
from datetime import datetime
from pathlib import Path

REPO = Path(__file__).resolve().parent.parent
SOURCES = [REPO / "settings" / "claude-settings.json", REPO / "settings" / "claude-hooks.json"]


def claude_dir() -> Path:
    env = os.environ.get("CLAUDE_CONFIG_DIR", "").strip()
    return Path(env).expanduser() if env else Path.home() / ".claude"


def load(path: Path) -> dict:
    text = path.read_text(encoding="utf-8").replace("__HOME__", str(Path.home()))
    return json.loads(text)


def merge(live: object, ours: object) -> object:
    """Deep merge: objects by key, arrays unioned, ours wins on scalars."""
    if live is None:
        return ours
    if ours is None:
        return live
    if isinstance(live, dict) and isinstance(ours, dict):
        out = dict(live)
        for key, value in ours.items():
            out[key] = merge(live.get(key), value)
        return out
    if isinstance(live, list) and isinstance(ours, list):
        seen = {json.dumps(item, sort_keys=True) for item in live}
        out = list(live)
        for item in ours:
            marker = json.dumps(item, sort_keys=True)
            if marker not in seen:
                out.append(item)
                seen.add(marker)
        return out
    return ours


def hook_commands(group: dict) -> set[str]:
    """The command strings a hook group runs."""
    return {
        hook.get("command")
        for hook in group.get("hooks", [])
        if isinstance(hook, dict) and hook.get("command")
    }


def merge_hooks(live_hooks: dict, our_hooks: dict) -> dict:
    """Converge per event instead of accumulating groups.

    A plain array union appends a group whose shape changed, so editing a group
    (adding a second hook to it, say) left the old one behind and both ran. For
    each event, drop every live group that runs one of our commands and append
    ours; foreign groups on the same event are kept.
    """
    merged = dict(live_hooks)
    for event, groups in our_hooks.items():
        if not isinstance(groups, list):
            merged[event] = groups
            continue
        ours = set().union(*(hook_commands(group) for group in groups)) if groups else set()
        kept = [group for group in merged.get(event, []) if not (hook_commands(group) & ours)]
        merged[event] = kept + groups
    return merged


def contains(live: object, ours: object, path: str = "") -> list[str]:
    """Return the paths from `ours` that are missing or different in `live`."""
    missing: list[str] = []
    if isinstance(ours, dict):
        if not isinstance(live, dict):
            return [path or "<root>"]
        for key, value in ours.items():
            missing.extend(contains((live or {}).get(key), value, f"{path}.{key}".lstrip(".")))
        return missing
    if isinstance(ours, list):
        if not isinstance(live, list):
            return [path or "<root>"]
        seen = {json.dumps(item, sort_keys=True) for item in live}
        for item in ours:
            if json.dumps(item, sort_keys=True) not in seen:
                missing.append(f"{path}[]")
        return missing
    if live != ours:
        return [path or "<root>"]
    return missing


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    group = parser.add_mutually_exclusive_group()
    group.add_argument("--dry-run", action="store_true", help="print the result, write nothing")
    group.add_argument("--check", action="store_true", help="exit 1 if a key is missing")
    group.add_argument("--restore", action="store_true", help="restore the most recent backup")
    args = parser.parse_args()

    target = claude_dir() / "settings.json"
    if args.restore:
        backups = sorted(claude_dir().glob("settings.json.bak.*"))
        if not backups:
            sys.exit("no backup to restore")
        newest = backups[-1]
        shutil.copy2(newest, target)
        print(f"restored {newest} -> {target}")
        return

    live = json.loads(target.read_text(encoding="utf-8")) if target.exists() else {}

    if args.check:
        problems: list[str] = []
        for source in SOURCES:
            problems.extend(contains(live, load(source)))
        if problems:
            print(f"{target}: {len(problems)} values missing")
            for problem in sorted(set(problems))[:20]:
                print(f"  - {problem}")
            sys.exit(1)
        print(f"{target}: every value from the repository is present")
        return

    merged = live
    for source in SOURCES:
        data = load(source)
        hooks = data.pop("hooks", None)
        merged = merge(merged, data)
        if hooks is not None:
            merged["hooks"] = merge_hooks(merged.get("hooks") or {}, hooks)

    rendered = json.dumps(merged, indent=2, ensure_ascii=False) + "\n"
    if args.dry_run:
        print(rendered)
        return

    if target.exists():
        stamp = datetime.now().strftime("%Y%m%d-%H%M%S")
        backup = claude_dir() / f"settings.json.bak.{stamp}"
        shutil.copy2(target, backup)
        print(f"backup: {backup}")
    target.parent.mkdir(parents=True, exist_ok=True)
    target.write_text(rendered, encoding="utf-8")
    print(f"written: {target}")


if __name__ == "__main__":
    main()
