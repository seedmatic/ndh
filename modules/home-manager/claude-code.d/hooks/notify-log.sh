#!/usr/bin/env bash
# Notification hook, step ① of notify-on-prompt: log every notification Claude Code sends, ping no one.
#
# The docs name the types (permission_prompt, idle_prompt, elicitation_dialog…) but not whether a prompt
# in the VS Code extension, or a hook's or the classifier's "ask", fires one. This log is the measure:
# one JSON line per event, with the session's engraved name when the registry knows it, so the
# notifying step is built on what actually fires. A Notification hook cannot block anything, and this
# one never fails the session: a malformed payload is logged as such.
set -uo pipefail

input="$(cat)"
field() { printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // "" | tostring' 2>/dev/null; }
session_id="$(field session_id)"

name=""
registry="${CLAUDE_SESSION_REGISTRY:-}"
if [[ -n "$session_id" && -r "$registry" ]]; then
  name="$(jq -r --arg s "$session_id" \
    '.sessions | to_entries[] | select(.value.conversations // [] | index($s)) | .key' "$registry" 2>/dev/null | head -1)"
fi

log="${XDG_STATE_HOME:-$HOME/.local/state}/claude-notify/log.jsonl"
mkdir -p "$(dirname "$log")"
if printf '%s' "$input" | jq -e 'type == "object"' >/dev/null 2>&1; then
  printf '%s' "$input" | jq -c --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg name "$name" \
    '{ts: $ts, type: (.notification_type // ""), session_id: (.session_id // ""), name: $name,
      title: (.title // "" | tostring | .[0:120]), message: (.message // "" | tostring | .[0:240]),
      cwd: (.cwd // ""), keys: (keys)}' >>"$log"
else
  jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg raw "${input:0:240}" \
    '{ts: $ts, type: "unparsed", raw: $raw}' >>"$log"
fi
exit 0
