#!/usr/bin/env bash
# Smoke tests for the hooks. Feeds each one the JSON payload Claude Code sends
# and checks the decision. Uses a throwaway config dir, so nothing in the live
# configuration is touched.
#
#   scripts/selftest.sh
set -uo pipefail

cd "$(dirname "$0")/.." || exit 1
export CLAUDE_CONFIG_DIR=$(mktemp -d)
trap 'rm -rf "$CLAUDE_CONFIG_DIR"' EXIT

pass=0
fail=0

expect() {
  local name=$1 want=$2 got=$3
  if [[ $got == "$want" ]]; then
    printf '  ok    %s\n' "$name"
    pass=$((pass + 1))
  else
    printf '  FAIL  %s (expected %s, got %s)\n' "$name" "$want" "$got"
    fail=$((fail + 1))
  fi
}

# Decides whether a hook produced a deny/block decision. Empty output means the
# hook had no opinion, which is an allow.
decision() {
  local out
  out=$(cat)
  if [[ -z $out ]]; then
    echo allow
    return
  fi
  jq -r '.hookSpecificOutput.permissionDecision // .decision // "allow"' <<<"$out" 2>/dev/null || echo allow
}

# Whether a hook injected additional context.
injects() {
  local out
  out=$(cat)
  if [[ -z $out ]]; then
    echo allow
    return
  fi
  jq -r 'if .hookSpecificOutput.additionalContext then "context" else "allow" end' <<<"$out" 2>/dev/null || echo allow
}

# A transcript deep enough to trip the fork guard.
deep=$(mktemp)
printf '%s\n' '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"cache_read_input_tokens":745000,"cache_creation_input_tokens":0}}}' >"$deep"

got=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"fork"},"transcript_path":"%s"}' "$deep" | hooks/guard-deep-fork.sh | decision)
expect "fork at 745k: denies" deny "$got"

shallow=$(mktemp)
printf '%s\n' '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"cache_read_input_tokens":40000,"cache_creation_input_tokens":0}}}' >"$shallow"
got=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"fork"},"transcript_path":"%s"}' "$shallow" | hooks/guard-deep-fork.sh | decision)
expect "fork at 40k: allows" allow "$got"

got=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"Explore"},"transcript_path":"%s"}' "$deep" | hooks/guard-deep-fork.sh | decision)
expect "Explore at 745k: allows" allow "$got"

got=$(printf '{"tool_name":"Agent","tool_input":{"subagent_type":"general-purpose"},"transcript_path":"%s"}' "$deep" | hooks/guard-deep-fork.sh | decision)
expect "general-purpose at 745k: allows" allow "$got"

got=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/tmp/claude-1000/x/tasks/a1.output"}}' | hooks/guard-transcript-reads.sh | decision)
expect "Read of a .output: denies" deny "$got"

got=$(printf '{"tool_name":"Bash","tool_input":{"command":"cat /tmp/claude-1000/x/tasks/a1.output | tail -3"}}' | hooks/guard-transcript-reads.sh | decision)
expect "cat of a .output: denies" deny "$got"

got=$(printf '{"tool_name":"Bash","tool_input":{"command":"grep -c ERROR /tmp/claude-1000/x/tasks/a1.output"}}' | hooks/guard-transcript-reads.sh | decision)
expect "bounded grep: allows" allow "$got"

got=$(printf '{"tool_name":"Read","tool_input":{"file_path":"src/main.py"}}' | hooks/guard-transcript-reads.sh | decision)
expect "Read of a normal file: allows" allow "$got"

got=$(printf '{"from_model":"claude-sonnet-5-5","to_model":"claude-opus-5-5","context_tokens":400000,"prompt_cache_warm":true}' | hooks/guard-model-switch.sh | decision)
expect "sonnet→opus at 400k: denies" deny "$got"

got=$(printf '{"from_model":"claude-sonnet-5-5","to_model":"claude-opus-5-5","context_tokens":30000}' | hooks/guard-model-switch.sh | decision)
expect "sonnet→opus at 30k: allows" allow "$got"

got=$(printf '{"from_model":"claude-opus-5-5","to_model":"claude-sonnet-5-5","context_tokens":400000}' | hooks/guard-model-switch.sh | decision)
expect "opus→sonnet at 400k: allows" allow "$got"

long=$(printf 'x%.0s' $(seq 1 5000))
got=$(printf '%s' "$(jq -n --arg m "$long" '{agent_id:"a1",last_assistant_message:$m}')" | hooks/guard-subagent-report.sh | decision)
expect "5000-char report: blocks" block "$got"

got=$(printf '%s' "$(jq -n --arg m "$long" '{agent_id:"a1",last_assistant_message:$m}')" | hooks/guard-subagent-report.sh | decision)
expect "same agent, second attempt: allows" allow "$got"

got=$(printf '{"prompt":"<task-notification><task-id>x</task-id>"}' | hooks/loop-concision.sh | injects)
expect "poll: injects concision" context "$got"

got=$(printf '{"prompt":"fix the parser bug"}' | hooks/loop-concision.sh | injects)
expect "normal prompt: no injection" allow "$got"

# --- context meter and checkpoints ---
state="$CLAUDE_CONFIG_DIR/hooks/.state"
printf '{"session_id":"m1","transcript_path":"%s"}' "$deep" | hooks/context-meter.sh
read -r got delta out <"$state/context-m1"
expect "meter records the context" 745001 "$got"
expect "meter records the delta on the first turn" 745001 "$delta"

printf '{"session_id":"m1","transcript_path":"%s"}' "$deep" | hooks/context-meter.sh
read -r got delta out <"$state/context-m1"
expect "meter records no delta when nothing grew" 0 "$delta"

sid="s1"
ckpt() { printf '{"session_id":"%s","tool_name":"Bash"}' "$1" | hooks/context-checkpoint.sh | decision; }

echo "150000 1600 900" >"$state/context-$sid"
expect "context 150k: allows" allow "$(ckpt "$sid")"

echo "250000 1600 900" >"$state/context-$sid"
expect "context 250k: asks" ask "$(ckpt "$sid")"

expect "context 250k again: no second prompt" allow "$(ckpt "$sid")"

echo "450000 1600 900" >"$state/context-$sid"
expect "context 450k: asks again" ask "$(ckpt "$sid")"

expect "context 450k again: no second prompt" allow "$(ckpt "$sid")"

echo "650000 1600 900" >"$state/context-$sid"
expect "context 650k: asks at the 600k tier" ask "$(ckpt "$sid")"

reason=$(printf '{"session_id":"s1","tool_name":"Bash"}' | hooks/context-checkpoint.sh >/dev/null; echo)
echo "850000 1600 900" >"$state/context-$sid"
reason=$(printf '{"session_id":"s1","tool_name":"Bash"}' | hooks/context-checkpoint.sh | jq -r '.hookSpecificOutput.permissionDecisionReason // empty')
if [[ $reason == *'$0.'* ]]; then
  expect "the prompt carries a per-turn cost" yes yes
else
  expect "the prompt carries a per-turn cost" "a dollar figure" "${reason:-<empty>}"
fi

expect "unknown session: allows" allow "$(printf '{"session_id":"nope"}' | hooks/context-checkpoint.sh | decision)"

rm -f "$deep" "$shallow"
echo
printf '%d ok, %d failed\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
