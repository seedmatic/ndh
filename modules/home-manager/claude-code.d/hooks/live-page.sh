#!/usr/bin/env bash
# SessionStart hook: register the session with the integration, name it after its chantier, and hand it the
# integration's live page.
#
# Several sessions run at once and the operator cannot always tell the integration that one was opened, so every
# start leaves a line in the integration's register: a session the integration did not launch is still seen.
# A reload renames every session (develop-ab became develop-e2, then develop), while the conversation id survives; so
# a session engraved in security's registry (the installed owned-dirs.json) is given its registry name at EVERY start,
# resume or fork: a title already set is not enough, since the name the other sessions message it by reverted after a
# cold restart while the title stayed. A session not engraved keeps today's rule: its LIVE.md's `> title:` comes back
# unless the operator already named it. A name is never guessed.
# The page's header and the sections a newcomer needs ("Ce qui t'attend", the session tree) are injected rather
# than merely named, because a pointer is something a session can skip.
set -euo pipefail

scratch="${CLAUDE_SCRATCHPAD:-$HOME/.claude/.scratchpad.d}"
sow="$scratch/integration-sow"
page="$sow/LIVE.md"

input="$(cat)"
field() { printf '%s' "$input" | jq -r --arg k "$1" '.[$k] // ""'; }
session_id="$(field session_id)"
source="$(field source)"
cwd="$(field cwd)"
transcript="$(field transcript_path)"
current_title="$(field session_title)"
registry="${CLAUDE_SESSION_REGISTRY:-}"

registered=""
if [[ -n "$session_id" && -r "$registry" ]]; then
  registered="$(SID="$session_id" yq -p=json -o=yaml \
    '.sessions | to_entries[] | select((.value.conversations // [])[] == strenv(SID)) | .key' "$registry" | head -1)"
fi

# The chantier page that claims this conversation, and the title it declares.
own=""
declared=""
if [[ -n "$session_id" ]]; then
  own="$(grep -lxF "> conversation: ${session_id}" "$scratch"/*/LIVE.md 2>/dev/null | head -1 || true)"
fi
if [[ -n "$own" ]]; then
  declared="$(sed -n 's/^> title: //p' "$own" | head -1)"
fi
chantier=""
[[ -n "$own" ]] && chantier="$(basename "$(dirname "$own")")"

mkdir -p "$sow"
jq -cn --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" --arg id "$session_id" --arg source "$source" \
  --arg cwd "$cwd" --arg transcript "$transcript" --arg chantier "$chantier" \
  --arg title "${registered:-${current_title:-$declared}}" \
  '{ts: $ts, session_id: $id, source: $source, cwd: $cwd, transcript: $transcript, chantier: $chantier, title: $title}' \
  >>"$sow/sessions.jsonl"

case "$source" in
  startup | clear | resume | fork) ;;
  *) exit 0 ;;
esac

title=""
if [[ -n "$registered" && "$source" != clear ]]; then
  title="$registered"
elif [[ -z "$current_title" && -n "$declared" && "$source" != clear ]]; then
  # Not engraved: the operator's /rename wins, otherwise the chantier's declared title is restored.
  title="$declared"
fi

naming="Names change at every reload, the conversation id does not: this conversation is ${session_id}. Your chantier's LIVE.md must carry, in its header, the two lines \`> conversation: ${session_id}\` and \`> title: <chantier-name>\`; this hook then gives the session its title back at every resume. After a reload, run ListAgents to read your current name and tell the integration if it changed."

if [[ -n "$own" && "$source" == resume ]]; then
  context="You are the ${chantier} session (title ${registered:-${current_title:-$declared}}); your live page is ${own}. Re-read it, and the integration's ${page}, before going on. ${naming}"
else
  rules="Every session keeps its OWN live page at ${scratch}/<chantier>/LIVE.md (state, lead held, branch, what waits for the operator), updated at every step; the integration session synthesises the fleet view from them. Every document written for the operator opens with the figures that synthesise it. This session is registered in ${sow}/sessions.jsonl. If you are not the integration session, announce yourself to it before writing anything. ${naming}"
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
fi

jq -n --arg c "$context" --arg t "$title" \
  '{hookSpecificOutput: ({hookEventName: "SessionStart", additionalContext: $c} + (if $t == "" then {} else {sessionTitle: $t} end))}'
