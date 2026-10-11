#!/usr/bin/env bash
# SessionStart hook: register the session with the integration, and hand it the integration's live page.
#
# Several sessions run at once and the operator cannot always tell the integration that one was opened, so every
# start leaves a line in the integration's register: a session the integration did not launch is still seen.
# The page's header and the sections a newcomer needs ("Ce qui t'attend", the session tree) are injected rather
# than merely named, because a pointer is something a session can skip.
set -euo pipefail

sow="${CLAUDE_INTEGRATION_SOW:-$HOME/.claude/.scratchpad.d/integration-sow}"
page="$sow/LIVE.md"

input="$(cat)"
field() { printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // ""'; }
session_id="$(field session_id)"
source="$(field source)"
cwd="$(field cwd)"
transcript="$(field transcript_path)"

mkdir -p "$sow"
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg id "$session_id" --arg source "$source" \
  --arg cwd "$cwd" --arg transcript "$transcript" \
  '{ts: $ts, session_id: $id, source: $source, cwd: $cwd, transcript: $transcript}' >>"$sow/sessions.jsonl"

# Only a fresh start needs the briefing; a compaction or a resume already carries it.
case "$source" in
  startup | clear) ;;
  *) exit 0 ;;
esac

rules="Every session keeps its OWN live page at ~/.claude/.scratchpad.d/<chantier>/LIVE.md (state, lead held, branch, what waits for the operator), updated at every step; the integration session synthesises the fleet view from them. This session is registered as ${session_id} in ${sow}/sessions.jsonl. If you are not the integration session, announce yourself to it before writing anything."

if [[ -f "$page" ]]; then
  excerpt="$(awk '
    /^## / { keep = ($0 ~ /^## (1|4)\./) }
    !seen && /^## / { seen = 1 }
    !seen || keep' "$page")"
  context="Read ${page} first: it is the integration session's live page (who integrates, what is in progress, who holds which lead, the decisions in force). ${rules}

${excerpt}"
else
  context="The integration's live page ${page} does not exist: no integration session is declared. ${rules}"
fi

jq -n --arg c "$context" '{hookSpecificOutput: {hookEventName: "SessionStart", additionalContext: $c}}'
