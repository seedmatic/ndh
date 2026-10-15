#!/usr/bin/env bash
# Shared guard: in a repository that holds a flake, no tracked file may resolve to a sops filter. The
# global git config defines the sops clean/smudge filters, and their smudge leaves a file in the CLEAR
# on disk, where any session reading the worktree puts it in its transcript and a hand-typed `nix …`
# without ?rev= copies it into the store (the 2026-10-10 leak). Flake repositories are protected by
# naming no sops filter at all.
#
# The RESOLVED attribute decides, wherever it comes from: a .gitattributes (staged or in the worktree,
# at any depth), .git/info/attributes, or the global attributes file. So the question goes to
# `git check-attr`, which resolves them all; reading the .gitattributes files would miss the others.
#
# Sourced by the global pre-commit (refuses), post-checkout and post-merge (announce), and the Claude
# SessionStart hook (announces).

# True when the repository holds a flake at ANY depth, in its index or at HEAD: a flake evaluated from a
# subdirectory still copies the whole repository into the store.
repo_holds_flake() {
  [ -n "$(git ls-files -- flake.nix ':(glob)**/flake.nix' 2>/dev/null)" ] ||
    git ls-tree -r --name-only HEAD 2>/dev/null | grep -qE '(^|/)flake\.nix$'
}

# "<path> filter=<value>" for each tracked file whose resolved filter is sops-*. With --cached, the
# staged .gitattributes are read; without, the worktree's. .git/info/attributes and the global
# attributes file count in both.
sops_filtered_paths() {
  local p v
  git ls-files -z | git check-attr ${1:+"$1"} -z --stdin filter |
    while IFS= read -r -d "" p && IFS= read -r -d "" _ && IFS= read -r -d "" v; do
      if [[ "$v" == sops-* ]]; then printf '%s filter=%s\n' "$p" "$v"; fi
    done
}

# Both views, once each.
sops_filtered_paths_any() {
  { sops_filtered_paths --cached; sops_filtered_paths; } | sort -u
}

# True when the worktree copy of PATH is a sops file in the clear: present, and no sops metadata in it.
is_decrypted_on_disk() {
  [ -f "$1" ] && ! grep -qE '^sops:|"sops"[[:space:]]*:' "$1"
}
