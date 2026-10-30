#!/usr/bin/env bash
# PreToolUse hook on SendMessage: a message to a live session whose prompt cache has expired makes it re-write its
# whole context at the write rate. Measured over 72 h on 2026-10-30, those re-writes were 40% of the fleet's cost, and
# the integration's messages to idle sessions were a large part of them. So the first such message is refused once,
# with its price; the same message sent again to the same session, still idle, passes: the sender decides, knowingly,
# and the operator is not prompted.
#
# The target is read from Claude Code's own session registry (~/.claude/sessions/<pid>.json: name, socket, sessionId),
# its state from the tail of its transcript: the last response's time, its context, and the TTL it wrote its cache with
# (1 h or 5 min, from the usage's cache_creation split). A target not found, or with a small context, passes silently.
set -euo pipefail

input="$(cat)"
field() { printf '%s' "$input" | yq -p=json -o=json -r "$1 // \"\"" 2>/dev/null || true; }
[[ "$(field .tool_name)" == SendMessage ]] || exit 0
to="$(field .tool_input.to)"
[[ -n "$(field .tool_input.message)" && -n "$to" ]] || exit 0

claude="${CLAUDE_HOME:-$HOME/.claude}"
min_context="${CLAUDE_WAKE_MIN_CONTEXT:-100000}"
# Units per million input tokens, calibrated on a session's /cost on 2026-10-30; the price is a scale, not an invoice.
usd_per_m="${CLAUDE_WAKE_USD_PER_M:-3.3}"

name="${to%% \[*}"
sock=""
[[ "$name" == uds:* ]] && sock="${name#uds:}"
target=""
for f in "$claude"/sessions/*.json; do
  [[ -r "$f" ]] || continue
  if [[ -n "$sock" ]]; then
    hit="$(S="$sock" yq -p=json -r 'select(.messagingSocketPath == strenv(S)) | .sessionId' "$f" 2>/dev/null || true)"
  else
    hit="$(N="$name" yq -p=json -r 'select(.name == strenv(N)) | .sessionId' "$f" 2>/dev/null || true)"
  fi
  [[ -n "$hit" ]] && target="$hit" && break
done
[[ -n "$target" ]] || exit 0
transcript="$(find "$claude/projects" -maxdepth 2 -name "$target.jsonl" -print -quit 2>/dev/null || true)"
[[ -r "$transcript" ]] || exit 0

# The last response with a usage: its time, its context, and 3600 when it wrote a 1 h cache, else 300.
last="$(tail -n 400 "$transcript" | yq -p=json -r 'select(.message.usage) |
  [.timestamp, ((.message.usage.input_tokens // 0) + (.message.usage.cache_read_input_tokens // 0) + (.message.usage.cache_creation_input_tokens // 0)),
   (.message.usage.cache_creation.ephemeral_1h_input_tokens // 0)] | @tsv' 2>/dev/null | awk 'NF' | tail -1)"
[[ -n "$last" ]] || exit 0
IFS=$'\t' read -r ts context w1h <<<"$last"
((context >= min_context)) || exit 0
ttl=300
((w1h > 0)) && ttl=3600
then_epoch="$(printf '%s\n' "$ts" | yq -p=yaml -r 'with_dtf("2006-01-02T15:04:05.999Z07:00"; to_unix)' 2>/dev/null || true)"
[[ -n "$then_epoch" ]] || exit 0
idle=$(($(date +%s) - ${then_epoch%.*}))
((idle > ttl)) || exit 0

# Once per target and per idle period: the mark names the target's last response, so a new response re-arms it.
marks="$claude/.wake-cost-guard.d"
mark="$marks/$target.$then_epoch"
if [[ -e "$mark" ]]; then
  rm -f "$mark"
  exit 0
fi
mkdir -p "$marks"
find "$marks" -type f -mmin +1440 -delete 2>/dev/null || true
: >"$mark"

rate=1.25
((ttl == 3600)) && rate=2
cost="$(awk -v c="$context" -v r="$rate" -v u="$usd_per_m" 'BEGIN { printf "%.2f", c * r * u / 1e6 }')"
T="$to" C="$((context / 1000))" I="$((idle / 60))" L="$((ttl / 60))" D="$cost" yq -n -o=json -I0 '{"hookSpecificOutput": {
  "hookEventName": "PreToolUse", "permissionDecision": "deny",
  "permissionDecisionReason": ("Wake cost: " + strenv(T) + " has been idle " + strenv(I) + " min, past its " + strenv(L) +
    " min prompt cache; this message makes it re-write its " + strenv(C) + "k-token context (about $" + strenv(D) +
    "). Send only what it needs now, grouped; send the same message again to proceed.")}}'
