#!/usr/bin/env bash
# Stop · no matcher
#
# Records three numbers once per turn, so the checkpoint hook never has to parse
# the transcript on every tool call:
#
#   context  the tokens the next request will re-send
#   delta    the new tokens this turn added (context minus the previous context)
#   output   the output tokens of the last response
#   stamp    the epoch second this turn ended, so cache-watch.sh can tell how
#            long the session has been idle and whether the cache expired
#
# delta and output are what make a per-turn cost estimate accurate: the context
# is re-read at the cache price, but the new content is written at the write price
# and the output at the output price.
set -uo pipefail

payload=$(cat)
session=$(jq -r '.session_id // empty' <<<"$payload" 2>/dev/null)
transcript=$(jq -r '.transcript_path // empty' <<<"$payload" 2>/dev/null)
[[ -n $session && -f ${transcript:-} ]] || exit 0

line=$(tail -n 4000 "$transcript" 2>/dev/null \
    | grep -F '"type":"assistant"' \
    | tail -n 20 \
    | tac \
    | jq -r 'select(.message.usage)
        | [(.message.usage.input_tokens
            + .message.usage.cache_read_input_tokens
            + .message.usage.cache_creation_input_tokens),
           (.message.usage.output_tokens // 0)] | @tsv' 2>/dev/null \
    | head -1)

[[ -n $line ]] || exit 0
context=${line%%$'\t'*}
output=${line##*$'\t'}
[[ $context =~ ^[0-9]+$ && $output =~ ^[0-9]+$ ]] || exit 0

state="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/.state"
mkdir -p "$state"
file="$state/context-$session"

previous=0
if [[ -f $file ]]; then
  previous=$(cut -d' ' -f1 "$file" 2>/dev/null)
  [[ $previous =~ ^[0-9]+$ ]] || previous=0
fi

delta=$((context - previous))
(( delta < 0 )) && delta=0

printf '%s %s %s %s\n' "$context" "$delta" "$output" "$(date +%s)" >"$file"
exit 0
