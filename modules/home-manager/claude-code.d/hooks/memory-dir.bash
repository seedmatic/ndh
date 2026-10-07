# Sourced by the memory hooks: the memory directory in force for a project, resolved the way
# Claude Code layers its settings (user, then project, then local; the last one set wins).
# Empty when no level redirects memory, in which case there is nothing to guard or commit.
memory_dir() {
  local root="$1" f v dir=""
  for f in "$HOME/.claude/settings.json" "$root/.claude/settings.json" "$root/.claude/settings.local.json"; do
    [[ -f "$f" ]] || continue
    v="$(jq -r '.autoMemoryDirectory // empty' "$f" 2>/dev/null)" || continue
    [[ -n "$v" ]] && dir="$v"
  done
  [[ "$dir" == "~/"* ]] && dir="$HOME/${dir#\~/}"
  printf '%s' "$dir"
}
