#!/usr/bin/env bash
# SessionEnd hook: commit (and push) the memory files THIS session wrote.
#
# The session that WRITES memory is never the one that commits from that checkout: the memory is
# its own worktree. Nothing closed that gap, so memory accumulated UNCOMMITTED — measured
# 2026-09-29, 32 files dirty for 11 days, and the divergence made a dead-link audit report 7 live
# facts as dead.
#
# Only this session's files, by the operator's decision of 2026-10-07: the memory worktree is shared
# by every session, and each commits its own paths. "This session's" means what its transcript shows
# it writing with Write, Edit, MultiEdit or NotebookEdit. A write made through Bash (a heredoc, a
# `sed -i`) does not show there and is committed by hand; memory-guard reports it at the next start.
#
# Never fails the session — a memory that cannot be committed is reported, not fatal.
set -uo pipefail

input="$(cat 2>/dev/null || true)"
session_id="$(printf '%s' "$input" | jq -r '.session_id // empty' 2>/dev/null || true)"
transcript="$(printf '%s' "$input" | jq -r '.transcript_path // empty' 2>/dev/null || true)"
# shellcheck source=memory-dir.bash
source "$(dirname "${BASH_SOURCE[0]}")/memory-dir.bash"

note() { printf '{"systemMessage": "%s"}\n' "$1"; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dir="$(memory_dir "$repo_root")"
[[ -n "$dir" && -d "$dir" && -f "$transcript" ]] || exit 0
real_dir="$(cd "$dir" && pwd -P)"
git -C "$dir" symbolic-ref -q HEAD >/dev/null || exit 0

files=()
while IFS= read -r f; do
  [[ -n "$f" ]] || continue
  parent="$(cd "$(dirname "$f")" 2>/dev/null && pwd -P)" || continue
  rel="${parent}/$(basename "$f")"
  [[ "$rel" == "$real_dir"/* ]] || continue
  rel="${rel#"$real_dir"/}"
  [[ -n "$(git -C "$dir" status --porcelain -- "$rel")" ]] && files+=("$rel")
done < <(jq -r 'select(.type == "assistant") | .message.content[]?
    | select(.type == "tool_use" and (.name | IN("Write", "Edit", "MultiEdit", "NotebookEdit")))
    | .input.file_path // .input.notebook_path // empty' "$transcript" 2>/dev/null | sort -u)

((${#files[@]} > 0)) || exit 0

msg="memory: session writes"
[[ -n "$session_id" ]] && msg="memory: session ${session_id%%-*} writes"
# `commit -- <paths>` commits those paths only, whatever another session has staged.
if ! git -C "$dir" add -- "${files[@]}" || ! git -C "$dir" commit -q -m "$msg

${#files[@]} file(s) written by the session, committed by its SessionEnd hook." -- "${files[@]}"; then
  note "memory-commit: FAILED to commit ${#files[@]} file(s) in $dir — commit them by hand before they drift."
  exit 0
fi
if git -C "$dir" push -q 2>/dev/null; then
  note "memory-commit: committed + pushed ${#files[@]} memory file(s)."
else
  note "memory-commit: committed ${#files[@]} memory file(s) but the push FAILED — run 'git -C $dir push'."
fi
