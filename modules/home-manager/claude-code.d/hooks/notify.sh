#!/usr/bin/env bash
# Notification hook: a session that waits on the operator says so, and every notification is logged.
#
# Measured with the log alone (2026-10-18): in the VS Code extension, permission_prompt fires for a tool prompt and
# for a question (AskUserQuestion) alike, and idle_prompt never fired. So a permission_prompt, or an MCP dialog,
# raises a macOS notification naming the session by its engraved name; every type is still logged. The message
# reaches AppleScript as an argument, never as script text, so nothing in it can run. A Notification hook cannot
# block anything, and this one never fails the session: a malformed payload is logged as such.
set -uo pipefail

input="$(cat)"
field() { printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // "" | tostring' 2>/dev/null; }
session_id="$(field session_id)"
type="$(field notification_type)"

name=""
registry="${CLAUDE_SESSION_REGISTRY:-}"
if [[ -n "$session_id" && -r "$registry" ]]; then
  name="$(jq -r --arg s "$session_id" \
    '.sessions | to_entries[] | select(.value.conversations // [] | index($s)) | .key' "$registry" 2>/dev/null | head -1)"
fi

case "$type" in
  permission_prompt | elicitation_dialog | elicitation_url_dialog)
    message="$(field message)"
    # Fixed at build (package.nix: /usr/bin/osascript), never a PATH or environment lookup; the bats substitute a
    # stand-in. Unsubstituted, it names no program and nothing runs.
    osascript="@osascript@"
    if [[ -x "$osascript" ]]; then
      "$osascript" -e 'on run argv' \
        -e 'display notification (item 2 of argv) with title (item 1 of argv) sound name "Glass"' \
        -e 'end run' "Claude · ${name:-${session_id:0:8}}" "${message:0:200}" >/dev/null 2>&1 || true
    fi
    ;;
esac

log="${XDG_STATE_HOME:-$HOME/.local/state}/claude-notify/log.jsonl"
# Session names and paths are the operator's alone: the directory 0700, the log 0600.
umask 077
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
