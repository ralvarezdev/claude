#!/usr/bin/env bash
# PreModelSwitch · sin matcher
#
# Any model switch discards the prompt cache, because every model has its own.
# Switching to a more expensive family also multiplies the per-token price. With
# a deep context that is the worst moment to do either.
#
# Allowed on purpose:
#   - a downgrade, which pays one rebuild to make every later turn cheaper;
#   - a same-tier switch, which no hook can make cache-preserving anyway.
#
# The event input already carries context_tokens and prompt_cache_warm, so this
# never reads the transcript.
set -uo pipefail

payload=$(cat)
from=$(jq -r '.from_model // empty' <<<"$payload" 2>/dev/null)
to=$(jq -r '.to_model // empty' <<<"$payload" 2>/dev/null)
context=$(jq -r '.context_tokens // 0' <<<"$payload" 2>/dev/null)
warm=$(jq -r '.prompt_cache_warm // false' <<<"$payload" 2>/dev/null)

# Tier by family. Unknown models (gateway ids) count as more expensive: when in
# doubt, ask the user first.
tier() {
  case ${1,,} in
    *haiku*)          echo 1 ;;
    *sonnet*)         echo 2 ;;
    *opus*)           echo 3 ;;
    *fable*|*mythos*) echo 4 ;;
    *)                echo 9 ;;
  esac
}

from_tier=$(tier "$from")
to_tier=$(tier "$to")

(( to_tier < from_tier )) && exit 0
(( to_tier == from_tier )) && exit 0

limit=${DEEP_SWITCH_LIMIT:-150000}
[[ $context =~ ^[0-9]+$ ]] || exit 0
(( context >= limit )) || exit 0

jq -n --arg from "$from" --arg to "$to" --argjson ctx "$context" --argjson warm "$warm" '{
  hookSpecificOutput: {
    hookEventName: "PreModelSwitch",
    permissionDecision: "deny",
    permissionDecisionReason:
      ("Salto a un modelo de gama superior (" + $from + " → " + $to + ") con "
       + ($ctx | tostring) + " tokens de contexto y el caché "
       + (if $warm then "caliente" else "frío" end)
       + ". Cada turno pasa a costar más y el prefijo se reenvía entero. "
       + "Terminá la tarea o hacé /clear antes de cambiar.")
  }
}'
exit 0
