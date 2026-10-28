#!/usr/bin/env bash
# UserPromptSubmit · no matcher
#
# Warns when the prompt cache has already expired, and blocks the prompt when the
# rebuild is expensive enough to be worth a decision.
#
# Why blocking: this hook runs before the request, but returning a message does
# not stop the request. A warning the user cannot act on is theatre — the cold
# turn goes out and the rebuild is paid. So above CACHE_WATCH_BLOCK_USD the prompt
# is refused once, the user runs /clear or resends deliberately, and the second
# attempt goes through.
#
# Expiry is deterministic: the entry lives for its TTL counted from the last
# request that used it, so `last turn + TTL` is arithmetic, not a heuristic.
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
message="Cache expired: ${minutes} min idle, TTL ${ttl_minutes} min. Sending this re-reads ${context} tokens and rewrites them: about \$${rebuild} once, then back to normal."

# Block once per idle episode, keyed on the timestamp of the last turn: the user
# gets one decision, and the resend goes through.
threshold=${CACHE_WATCH_BLOCK_USD:-0.50}
worth_it=$(awk -v r="$rebuild" -v t="$threshold" 'BEGIN { print (r >= t) ? "yes" : "no" }')

if [[ $worth_it == yes ]]; then
  episode="$state/cacheblock-$session-$stamp"
  if [[ ! -f $episode ]]; then
    : >"$episode"
    jq -n --arg msg "$message" '{
      decision: "block",
      reason: ($msg + " The prompt was not sent. Run /clear and resend to start clean, or resend to continue with this context and pay it.")
    }'
    exit 0
  fi
fi

jq -n --arg msg "$message" '{
  systemMessage: $msg,
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: ($msg + " If the task is finished, say so instead of continuing.")
  }
}'
exit 0
