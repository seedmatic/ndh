#!/usr/bin/env bash
# SessionStart hook: a model with a 1M window ([1m]) lets a session ride its context far past 200k, and every response
# re-reads all of it. Measured on 2026-10-31: 49% of the cost since the cache fix came from requests above 200k, from
# sessions started on `opus[1m]`, which the /model picker writes back into ~/.claude/settings.json. A session start
# cannot be refused, so the operator and the session are both told, before the first response.
set -euo pipefail

input="$(cat)"
claude="${CLAUDE_HOME:-$HOME/.claude}"
model="$(printf '%s' "$input" | yq -p=json -r '.model // ""' 2>/dev/null || true)"
[[ -n "$model" ]] || model="$(yq -p=json -r '.model // ""' "$claude/settings.json" 2>/dev/null || true)"
[[ "$model" == *"[1m]"* ]] || exit 0

M="$model" yq -n -o=json -I0 '{"systemMessage": ("Model " + strenv(M) + " has a 1M window: run /model and pick the 200k one, then restart."),
  "hookSpecificOutput": {"hookEventName": "SessionStart", "additionalContext": ("This session runs " + strenv(M) +
    ", a 1M-token window: past 200k every response re-reads the whole context. Tell the operator first thing, and keep the context small until they restart it on the 200k model.")}}'
