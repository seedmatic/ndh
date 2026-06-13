#!/usr/bin/env bash
# Shared guard: a `wip/` or `.wip/` directory at ANY depth must never reach a
# protected branch — the shared-history branches main and develop.
#
# wip/ holds living process artifacts (brainstorm -> spec -> plan) DURING a feature
# branch; its durable substance migrates into the shared history before merge. The
# block at the protected-branch boundary is the forcing function: promote it or
# delete it. develop is guarded as well as main, so work-in-progress never enters
# integration either.
#
# Sourced by both pre-commit (commits / squash-merges, via the staged index) and
# pre-push (catch-all, including fast-forward merges, via the pushed tree).

# The shared-history branches that wip/ must never reach.
PROTECTED_BRANCHES=("main" "develop")
# A directory segment exactly `wip` or `.wip` (so `swipe/`, `wiping.md`, and a bare
# file named `wip` do not match).
WIP_RE='(^|/)\.?wip/'

# True when $1 names a protected branch.
is_protected_branch() {
  local b
  for b in "${PROTECTED_BRANCHES[@]}"; do
    [ "$1" = "$b" ] && return 0
  done
  return 1
}

# Echo tracked wip paths staged in the index, one per line (empty if none).
wip_paths_in_index() {
  git ls-files | grep -E "$WIP_RE" || true
}

# Echo tracked wip paths in the given tree-ish, one per line (empty if none).
wip_paths_in() {
  git ls-tree -r --name-only "$1" 2>/dev/null | grep -E "$WIP_RE" || true
}

# $1 = newline-separated wip paths, $2 = the protected branch they were headed for.
reject() {
  echo "─────────────────────────────────────────────────────────────" >&2
  echo "  BLOCKED: a wip/ or .wip/ path must not reach '${2}'." >&2
  echo "" >&2
  echo "  These work-in-progress paths are on the way to ${2}:" >&2
  while IFS= read -r p; do [ -n "$p" ] && echo "    • $p" >&2; done <<< "$1"
  echo "" >&2
  echo "  Promote their durable substance into the shared history and delete the" >&2
  echo "  wip path, or keep the work on a feature branch." >&2
  echo "─────────────────────────────────────────────────────────────" >&2
}

# Chain to the FIRST repo-local hook of $name that exists, is executable, and is not
# this dispatcher itself. Forwards args and stdin via exec (propagates its exit).
# $1 = hook name, $2 = this dispatcher's own directory (never re-invoked).
chain_repo_local() {
  local name="$1" self_dir="$2"; shift 2
  local git_dir cand cand_dir
  git_dir="$(git rev-parse --git-dir 2>/dev/null)" || return 0
  for cand in "${git_dir}/hooks/${name}" ".githooks/${name}"; do
    [ -x "$cand" ] || continue
    cand_dir="$(cd "$(dirname "$cand")" && pwd)"
    [ "$cand_dir" = "$self_dir" ] && continue
    exec "$cand" "$@"
  done
}
