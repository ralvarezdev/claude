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
    printf '  FAIL  %s (esperaba %s, obtuvo %s)\n' "$name" "$want" "$got"
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

got=$(printf '{"tool_name":"Agent","transcript_path":"%s"}' "$deep" | hooks/guard-deep-fork.sh | decision)
expect "fork con 745k: bloquea" deny "$got"

shallow=$(mktemp)
printf '%s\n' '{"type":"assistant","message":{"id":"m1","usage":{"input_tokens":1,"cache_read_input_tokens":40000,"cache_creation_input_tokens":0}}}' >"$shallow"
got=$(printf '{"tool_name":"Agent","transcript_path":"%s"}' "$shallow" | hooks/guard-deep-fork.sh | decision)
expect "fork con 40k: permite" allow "$got"

got=$(printf '{"tool_name":"Read","tool_input":{"file_path":"/tmp/claude-1000/x/tasks/a1.output"}}' | hooks/guard-transcript-reads.sh | decision)
expect "Read de .output: bloquea" deny "$got"

got=$(printf '{"tool_name":"Bash","tool_input":{"command":"cat /tmp/claude-1000/x/tasks/a1.output | tail -3"}}' | hooks/guard-transcript-reads.sh | decision)
expect "cat de .output: bloquea" deny "$got"

got=$(printf '{"tool_name":"Bash","tool_input":{"command":"grep -c ERROR /tmp/claude-1000/x/tasks/a1.output"}}' | hooks/guard-transcript-reads.sh | decision)
expect "grep acotado: permite" allow "$got"

got=$(printf '{"tool_name":"Read","tool_input":{"file_path":"src/main.py"}}' | hooks/guard-transcript-reads.sh | decision)
expect "Read normal: permite" allow "$got"

got=$(printf '{"from_model":"claude-sonnet-5-5","to_model":"claude-opus-5-5","context_tokens":400000,"prompt_cache_warm":true}' | hooks/guard-model-switch.sh | decision)
expect "sonnet→opus con 400k: bloquea" deny "$got"

got=$(printf '{"from_model":"claude-sonnet-5-5","to_model":"claude-opus-5-5","context_tokens":30000}' | hooks/guard-model-switch.sh | decision)
expect "sonnet→opus con 30k: permite" allow "$got"

got=$(printf '{"from_model":"claude-opus-5-5","to_model":"claude-sonnet-5-5","context_tokens":400000}' | hooks/guard-model-switch.sh | decision)
expect "opus→sonnet con 400k: permite" allow "$got"

long=$(printf 'x%.0s' $(seq 1 5000))
got=$(printf '%s' "$(jq -n --arg m "$long" '{agent_id:"a1",last_assistant_message:$m}')" | hooks/guard-subagent-report.sh | decision)
expect "reporte de 5000 chars: bloquea" block "$got"

got=$(printf '%s' "$(jq -n --arg m "$long" '{agent_id:"a1",last_assistant_message:$m}')" | hooks/guard-subagent-report.sh | decision)
expect "segundo intento del mismo agente: permite" allow "$got"

got=$(printf '{"prompt":"<task-notification><task-id>x</task-id>"}' | hooks/loop-concision.sh | injects)
expect "sondeo: inyecta concisión" context "$got"

got=$(printf '{"prompt":"arreglá el bug del parser"}' | hooks/loop-concision.sh | injects)
expect "prompt normal: no inyecta" allow "$got"

rm -f "$deep" "$shallow"
echo
printf '%d ok, %d fallos\n' "$pass" "$fail"
[[ $fail -eq 0 ]]
