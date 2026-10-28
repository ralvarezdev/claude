#!/usr/bin/env bash
# PreToolUse · matcher: Bash|Read|Write|Edit|Agent
#
# Asks for confirmation once per threshold per session, at 200k and at 400k of
# context. It reads a small state file written by context-meter.sh, so the cost
# on the hot path is a file read, not a transcript parse.
#
# The marker is written before the answer is known: the user is asked once, and
# a dismissal counts as answered too. Without that, every tool call above the
# threshold would prompt again.
set -uo pipefail

payload=$(cat)
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
[[ -n $session ]] || exit 0

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/.state"
context=$(cat "$state/context-$session" 2>/dev/null) || exit 0
[[ $context =~ ^[0-9]+$ ]] || exit 0

tier=0
if (( context >= 400000 )); then
  tier=400
elif (( context >= 200000 )); then
  tier=200
else
  exit 0
fi

marker="$state/ack-$session-$tier"
[[ -f $marker ]] && exit 0
: >"$marker"

# Cents per turn at the cache-read price of a Sonnet-class model ($0.10/M).
cents=$(( context * 10 / 1000000 ))
per_turn=$(printf '%d.%02d' $((cents / 100)) $((cents % 100)))

jq -n --argjson ctx "$context" --argjson tier "$tier" --arg per "$per_turn" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason:
      ("Context crossed " + ($tier | tostring) + "k: it is at " + ($ctx | tostring)
       + " tokens. Every turn from here re-sends all of it, about $" + $per
       + " per turn at cache-read price and several times that on a cache miss. "
       + "Continue with this context, or stop and /clear to start clean?")
  }
}'
exit 0
