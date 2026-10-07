#!/usr/bin/env bash
# SessionStart hook: verify memory is wired into a git worktree on a branch, and that its part is clean.
#
# Checked at START, not later, because a running session CANNOT be redirected: the path is
# resolved once into the system prompt. Measured 2026-09-29 — settings were corrected at
# 09-27 22:44 and writes were still landing in the old directory 14 h later. So a
# misconfiguration found mid-session costs the whole session's memory.
#
# The directory is the `autoMemoryDirectory` in force for the project, and only that: it may be the
# root of the memory worktree or one repository's subdirectory of it, and no branch or repository
# name is assumed. Only that directory's own dirt is reported — another subdirectory belongs to
# another repository's sessions.
set -uo pipefail

cat >/dev/null 2>&1 || true # drain the hook payload; nothing here needs it
# shellcheck source=memory-dir.bash
source "$(dirname "${BASH_SOURCE[0]}")/memory-dir.bash"

note() { printf '{"systemMessage": "%s"}\n' "$1"; }

repo_root="$(git rev-parse --show-toplevel 2>/dev/null || pwd)"
dir="$(memory_dir "$repo_root")"
[[ -n "$dir" ]] || exit 0

if [[ ! -d "$dir" ]]; then
  note "MEMORY WIRING: autoMemoryDirectory is '$dir', which does not exist — memory writes go nowhere a commit will find"
elif ! git -C "$dir" rev-parse --show-toplevel >/dev/null 2>&1; then
  note "MEMORY WIRING: autoMemoryDirectory '$dir' is not inside a git worktree — writes there are never committed"
elif ! git -C "$dir" symbolic-ref -q HEAD >/dev/null; then
  note "MEMORY WIRING: the memory worktree of '$dir' is on a detached HEAD — a commit there would belong to no branch"
elif [[ -n "$(git -C "$dir" status --porcelain -- .)" ]]; then
  n="$(git -C "$dir" status --porcelain -- . | wc -l | tr -d ' ')"
  note "MEMORY WIRING: the memory worktree has $n uncommitted file(s) — written through Bash, or by a session still running; the SessionEnd hook commits only its own session's Write/Edit, so commit yours by hand"
fi
