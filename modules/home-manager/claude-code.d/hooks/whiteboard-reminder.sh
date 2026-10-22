#!/usr/bin/env bash
# PostToolUse hook: a session that has just taken a step (sent a cross-session message, committed, pushed) without
# touching its live page in this turn is reminded to, in the tool's result, which it reads at once.
#
# The operator's rule is that every session keeps its LIVE.md, its whiteboard with them, up to date at every step; an
# instruction is forgotten, so this hook says it at the moment it matters (their choice of form, 2026-10-22). It never
# blocks and never forces a turn: it only adds context to a tool's result, so it cannot loop. A session that took no
# step (a paused one, a helper, the operator's own work outside a session) never triggers it; a session with no page
# is silent; a page already modified in the turn is silent.
#
# The page is the session's own: the LIVE.md under the scratchpad whose header names this conversation, as
# live-page.sh finds it. The turn starts at the transcript's last message the operator typed: an entry whose
# origin is `human` (a peer's message is `peer`, a tool result has none), measured on 2026-10-22's transcripts.
set -euo pipefail

input="$(cat)"
field() { printf '%s' "$input" | yq -p=json -o=json -r "$1 // \"\"" 2>/dev/null || true; }
tool="$(field .tool_name)"
case "$tool" in
  SendMessage) ;;
  Bash)
    # Only a commit or a push is a step: `git` at the start of one of the command's simple commands (after `;`, `&&`,
    # `||`, `|` or the start), never a word inside another command's arguments (`echo git commit`).
    cmd="$(field .tool_input.command)"
    printf '%s' "$cmd" |
      grep -qE '(^|;|&&|\|\||\|)[[:space:]]*git([[:space:]]+-C[[:space:]]+[^[:space:]]+)*[[:space:]]+(commit|push)([[:space:]]|$)' ||
      exit 0
    ;;
  *) exit 0 ;;
esac

session_id="$(field .session_id)"
transcript="$(field .transcript_path)"
[[ -n "$session_id" && -r "$transcript" ]] || exit 0
scratch="${CLAUDE_SCRATCHPAD:-$HOME/.claude/.scratchpad.d}"
page="$(grep -lxF "> conversation: ${session_id}" "$scratch"/*/LIVE.md 2>/dev/null | head -1 || true)"
[[ -n "$page" ]] || exit 0

# The transcript's tail first: the operator's last message is near its end, and the whole file of a long session
# (155 MB, measured) takes a second to read, which the hook's timeout would turn into silence. The whole file only when
# the tail holds none.
# `awk NF`, not `grep -v '^$'`: under pipefail a grep that matches nothing fails the pipeline and kills the hook before
# the fallback (measured); awk always exits 0.
last_human() { yq -p=json -o=json -r 'select(.type == "user" and .origin.kind == "human") | .timestamp // ""' 2>/dev/null |
  awk 'NF' | tail -1; }
start="$(tail -n 2000 "$transcript" | last_human)"
[[ -n "$start" ]] || start="$(last_human <"$transcript")"
start_epoch="$(printf '%s\n' "$start" | yq -p=yaml -r 'with_dtf("2006-01-02T15:04:05.999Z07:00"; to_unix)' 2>/dev/null || true)"
[[ -n "$start_epoch" ]] || exit 0
page_epoch="$(stat -c %Y "$page")"
((page_epoch < start_epoch)) || exit 0

what="a cross-session message"
[[ "$tool" == Bash ]] && what="a commit or a push"
P="$page" WHAT="$what" yq -n -o=json -I0 '{"hookSpecificOutput": {"hookEventName": "PostToolUse",
  "additionalContext": ("Whiteboard: you just made " + strenv(WHAT) + ", and your live page " + strenv(P) + " has not changed in this turn. Update it now, as the operator asks at every step: its Last update and Now lines, the figure if the state changed (validated), what remains, and any question for them.")}}'
