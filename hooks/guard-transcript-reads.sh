#!/usr/bin/env bash
# PreToolUse · matcher: Read|Bash
#
# Make the "do not read the subagent JSONL" warning executable. The warning is
# prompt text; this is the check. Files matched: *.output task transcripts and
# the JSONL transcripts under .claude/projects.
set -uo pipefail

payload=$(cat)
tool=$(jq -r '.tool_name // empty' <<<"$payload" 2>/dev/null)

case $tool in
  Read) target=$(jq -r '.tool_input.file_path // empty' <<<"$payload" 2>/dev/null) ;;
  Bash) target=$(jq -r '.tool_input.command // empty' <<<"$payload" 2>/dev/null) ;;
  *) exit 0 ;;
esac

[[ -n $target ]] || exit 0

# Only the paths that hold full transcripts.
transcript_re='\.output([^[:alnum:]]|$)|/tasks/[^/[:space:]]+$|/subagents/agent-[^/]*\.jsonl|/projects/[^/]+/[0-9a-f-]+\.jsonl'
[[ $target =~ $transcript_re ]] || exit 0

# For Bash, only block the commands that dump the file into the context.
if [[ $tool == Bash ]]; then
  dump_re='(^|[[:space:]|;&(])(cat|tail|head|less|more|bat|view|awk|sed)[[:space:]]'
  [[ $target =~ $dump_re ]] || exit 0
fi

jq -n '{
  hookSpecificOutput: {
    hookEventName: "PreToolUse",
    permissionDecision: "deny",
    permissionDecisionReason:
      "Full transcript of a task or subagent: reading it or tailing it dumps the whole history into the context. Use the agent'\''s final report, a bounded grep with | head -20, or the job'\''s status file."
  }
}'
exit 0
