#!/usr/bin/env bash
# UserPromptSubmit · no matcher
#
# Fires on every submitted prompt, including /loop iterations, scheduled tasks
# and background subagents reporting back. Those are the turns that should be
# short: a poll that answers with a paragraph costs the full context forever.
set -uo pipefail

payload=$(cat)
prompt=$(jq -r '.prompt // empty' <<<"$payload" 2>/dev/null)

[[ $prompt =~ (task-notification|\[loop|scheduled[[:space:]]task|wakeup) ]] || exit 0

jq -n '{
  hookSpecificOutput: {
    hookEventName: "UserPromptSubmit",
    additionalContext: "Poll or automated report: answer in ≤5 lines with the state (total, done, failed, ETA). Do not repeat logs, the plan, or what you already said."
  }
}'
exit 0
