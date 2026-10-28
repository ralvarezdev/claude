#!/usr/bin/env bash
# UserPromptSubmit · sin matcher
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
    additionalContext: "Sondeo o reporte automático: respondé en ≤5 líneas con el estado (total, hechos, fallos, ETA). No repitas logs, ni el plan, ni lo que ya dijiste."
  }
}'
exit 0
