#!/usr/bin/env bash
# Stop · no matcher
#
# Records the session's current context once per turn, so the checkpoint hook
# never has to parse the transcript on every tool call. This is the expensive
# half of the pair (it reads the tail of a file that can reach tens of megabytes)
# and it runs once per turn instead of once per tool call.
set -uo pipefail

payload=$(cat)
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
transcript=$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)
[[ -n $session && -f ${transcript:-} ]] || exit 0

context=$(tail -n 4000 "$transcript" 2>/dev/null \
    | grep -F '"type":"assistant"' \
    | tail -n 20 \
    | tac \
    | jq -r 'select(.message.usage)
        | .message.usage.input_tokens
        + .message.usage.cache_read_input_tokens
        + .message.usage.cache_creation_input_tokens' 2>/dev/null \
    | head -1)

[[ $context =~ ^[0-9]+$ ]] || exit 0

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/.state"
mkdir -p "$state"
printf '%s\n' "$context" >"$state/context-$session"
exit 0
