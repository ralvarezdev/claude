#!/usr/bin/env bash
# SubagentStop · no matcher
#
# A subagent's final message is copied verbatim into the parent's context. If it
# is a log dump, the parent pays for it on every later turn.
#
# Blocks once per agent to ask for a shorter report, then lets it through: a
# SubagentStop block means "keep working", so without the counter this could
# loop forever.
set -uo pipefail

payload=$(cat)
message=$(jq -r '.last_assistant_message // empty' <<<"$payload" 2>/dev/null)
agent=$(jq -r '.agent_id // "unknown"' <<<"$payload" 2>/dev/null)

limit=${SUBAGENT_REPORT_LIMIT:-4000}
(( ${#message} > limit )) || exit 0

state_dir="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/hooks/.state"
mkdir -p "$state_dir"
marker="$state_dir/report-${agent//[^A-Za-z0-9_-]/_}"
[[ -f $marker ]] && exit 0
: >"$marker"

jq -n --argjson n "${#message}" --argjson limit "$limit" '{
  decision: "block",
  reason: ("The final report is " + ($n | tostring) + " characters against a limit of "
           + ($limit | tostring) + ". Return only a JSON of ≤20 lines with the metrics "
           + "(run, trials, passed, failed, duration_s, first_error). Detail goes to a file.")
}'
exit 0
