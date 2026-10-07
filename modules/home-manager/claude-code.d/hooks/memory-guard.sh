#!/usr/bin/env bash
# SessionStart hook: verify memory is wired to a worktree of the `memory` branch, and that it is clean.
#
# Checked at START, not later, because a running session CANNOT be redirected: the path is
# resolved once into the system prompt. Measured 2026-09-29 — settings were corrected at
# 09-27 22:44 and writes were still landing in the old directory 14 h later. So a
# misconfiguration found mid-session costs the whole session's memory.
#
# The directory is the `autoMemoryDirectory` in force, whatever the project: the hook is installed
# per user and fires in every repository, and the memory it guards is one shared worktree.
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
elif [[ "$(git -C "$dir" rev-parse --abbrev-ref HEAD 2>/dev/null)" != "memory" ]]; then
  note "MEMORY WIRING: autoMemoryDirectory '$dir' is not a worktree of the 'memory' branch — writes there are never committed"
elif [[ -n "$(git -C "$dir" status --porcelain)" ]]; then
  n="$(git -C "$dir" status --porcelain | wc -l | tr -d ' ')"
  note "MEMORY WIRING: the memory worktree has $n uncommitted file(s) — written through Bash, or by a session still running; the SessionEnd hook commits only its own session's Write/Edit, so commit yours by hand"
fi
