#!/usr/bin/env bash
# PreToolUse hook: every response re-reads the whole context from the cache, so a long session costs in proportion to
# its size; measured on 2026-10-31, cache reads were 58% of the cost once the wakes were gone. Past a threshold the next
# tool call is refused once, asking the session to write its live page so a restart loses nothing; then it passes, and
# the refusal comes back every further step. A compaction brings the context back under the threshold and re-arms it.
# Subagents are not judged: their input names the parent's transcript.
set -euo pipefail

input="$(cat)"
field() { printf '%s' "$input" | yq -p=json -o=json -r "$1 // \"\"" 2>/dev/null || true; }
[[ -z "$(field .agent_id)" ]] || exit 0
session="$(field .session_id)"
transcript="$(field .transcript_path)"
[[ -n "$session" && -r "$transcript" ]] || exit 0

claude="${CLAUDE_HOME:-$HOME/.claude}"
at="${CLAUDE_CONTEXT_GUARD_AT:-150000}"
step="${CLAUDE_CONTEXT_GUARD_STEP:-25000}"

context="$(tail -n 400 "$transcript" | yq -p=json -r 'select(.message.usage) | ((.message.usage.input_tokens // 0) +
  (.message.usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0))' 2>/dev/null |
  awk 'NF' | tail -1)"
[[ -n "$context" ]] || exit 0

marks="$claude/.context-guard.d"
if ((context < at)); then
  rm -f "$marks/$session".* 2>/dev/null || true
  exit 0
fi
mark="$marks/$session.$(((context - at) / step))"
[[ -e "$mark" ]] && exit 0
mkdir -p "$marks"
find "$marks" -type f -mmin +1440 -delete 2>/dev/null || true
: >"$mark"

C="$((context / 1000))" A="$((at / 1000))" yq -n -o=json -I0 '{"hookSpecificOutput": {
  "hookEventName": "PreToolUse", "permissionDecision": "deny",
  "permissionDecisionReason": ("Context cost: this session is at " + strenv(C) + "k tokens, past " + strenv(A) +
    "k; every response re-reads all of it. Write your live page now (state, what remains, the next step), then tell the operator it is ready for a restart. Retry the call to proceed.")}}'
