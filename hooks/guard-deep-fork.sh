#!/usr/bin/env bash
# PreToolUse · matcher: Agent
#
# Deny a fork when the session context is already deep. A fork copies the whole
# conversation, so with the parent at 700k every turn of the child re-sends 700k.
# SubagentStart cannot block creation; this is the only place it can be done.
#
# Exit 0 with no output means "no opinion": the normal permission flow applies.
set -uo pipefail

payload=$(cat)
transcript=$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)
[[ -z $transcript || ! -f $transcript ]] && exit 0

limit=${DEEP_FORK_LIMIT:-150000}

# The transcript is written asynchronously and can lag a turn, so read the tail
# and take the most recent assistant usage. Bounded read: these files reach tens
# of megabytes.
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
(( context >= limit )) || exit 0

jq -n --argjson ctx "$context" --argjson limit "$limit" '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      ("Context is at " + ($ctx | tostring) + " tokens (limit " + ($limit | tostring) + "). "
       + "Do not fork: a fork copies the history and every turn of it re-sends that copy. "
       + "Use a fresh subagent with a brief, or /clear first.")
  }
}'
exit 0
