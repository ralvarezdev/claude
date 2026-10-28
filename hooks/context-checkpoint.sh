#!/usr/bin/env bash
# PreToolUse · matcher: Bash|Read|Write|Edit|Agent
#
# Asks for confirmation once per threshold per session. Default thresholds are
# 200k, 400k, 600k and 800k; override with CONTEXT_TIERS.
#
# It reads a small state file written by context-meter.sh (context, delta,
# output), so the hot path is a file read. The arithmetic only runs when a
# threshold is actually crossed, which is a handful of times per session.
#
# The estimate is not a guess: a turn costs
#     (context - delta) * read_price  +  delta * write_price  +  output * out_price
# where the first two terms are the cache hit and the new content. Measured
# against real sessions the formula lands within 6% of the observed cost per turn.
# The one thing it cannot know is the cache state, which is why the message also
# shows the cost of a rebuild.
set -uo pipefail

payload=$(cat)
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
[[ -n $session ]] || exit 0

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/.state"
file="$state/context-$session"
[[ -f $file ]] || exit 0

read -r context delta output <"$file" || exit 0
[[ $context =~ ^[0-9]+$ ]] || exit 0
[[ ${delta:-} =~ ^[0-9]+$ ]] || delta=0
[[ ${output:-} =~ ^[0-9]+$ ]] || output=0

tier=0
for candidate in ${CONTEXT_TIERS:-200000 400000 600000 800000}; do
  if (( context >= candidate )); then
    tier=$candidate
  fi
done
(( tier > 0 )) || exit 0

marker="$state/ack-$session-$tier"
[[ -f $marker ]] && exit 0
: >"$marker"

# USD per million tokens. Defaults are Sonnet 5.5 with a 1h cache TTL.
read -r typical cold < <(awk \
  -v c="$context" -v d="$delta" -v o="$output" \
  -v r="${CONTEXT_READ_PRICE:-0.10}" \
  -v w="${CONTEXT_WRITE_PRICE:-4.00}" \
  -v p="${CONTEXT_OUT_PRICE:-10.0}" \
  'BEGIN {
     typical = ((c - d) * r + d * w + o * p) / 1000000
     cold    = (c * w + o * p) / 1000000
     printf "%.2f %.2f", typical, cold
   }')

jq -n --argjson ctx "$context" --argjson tier "$tier" --arg typ "$typical" --arg cold "$cold" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "ask",
    permissionDecisionReason:
      ("Context crossed " + ($tier / 1000 | floor | tostring) + "k: it is at "
       + ($ctx | tostring) + " tokens. About $" + $typ + " per turn at this size, "
       + "or $" + $cold + " if the prefix has to be rebuilt. "
       + "Continue with this context, or stop and /clear to start clean?")
  }
}'
exit 0
