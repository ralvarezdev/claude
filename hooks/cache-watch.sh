#!/usr/bin/env bash
# UserPromptSubmit · no matcher
#
# Warns before the request goes out when the prompt cache has already expired.
# Unlike the cost of a turn, this is not an estimate: the cache lifetime is
# measured from the last request that used it, so expiry is
# `last turn + TTL`, and both numbers are local.
#
# The warning is one event, not a recurring cost: the cold turn rebuilds the
# prefix and the following turns are warm again.
set -uo pipefail

payload=$(cat)
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
[[ -n $session ]] || exit 0

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/.state"
file="$state/context-$session"
[[ -f $file ]] || exit 0

read -r context delta output stamp <"$file" || exit 0
[[ $context =~ ^[0-9]+$ && $stamp =~ ^[0-9]+$ ]] || exit 0
[[ ${output:-} =~ ^[0-9]+$ ]] || output=0

ttl=${CACHE_TTL_SECONDS:-3600}
now=$(date +%s)
idle=$((now - stamp))
(( idle > ttl )) || exit 0

read -r rebuild < <(awk \
  -v c="$context" -v o="$output" \
  -v w="${CONTEXT_WRITE_PRICE:-4.00}" \
  -v p="${CONTEXT_OUT_PRICE:-10.0}" \
  'BEGIN { printf "%.2f", (c * w + o * p) / 1000000 }')

minutes=$((idle / 60))
ttl_minutes=$((ttl / 60))

message="Cache expired: ${minutes} min idle, TTL ${ttl_minutes} min. This turn re-reads ${context} tokens and rewrites them: about \$${rebuild} once, then back to normal. /clear costs nothing."

jq -n --arg msg "$message" '{
  systemMessage: $msg,
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ($msg + " If the task is finished, say so instead of continuing.")
  }
}'
exit 0
