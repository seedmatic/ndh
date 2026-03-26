source @activationLogger@

main() {
  set -euo pipefail

  export PATH="@gitPath@:$PATH"
  if [ ! -d "$HOME/.config/zsh/.git" ]; then
    @gitBin@ clone --depth=1 https://github.com/nxmatic/zdotdir.git "$HOME/.config/zsh"
  else
    @gitBin@ -C "$HOME/.config/zsh" pull --ff-only
  fi

  # Keep PNPM_HOME user-relative even if upstream zdotdir contains a stale
  # absolute path from a previous account migration.
  local zshrc_file="$HOME/.config/zsh/rcs/zshrc.zsh"

  # Guardrail: recover zshrc from git if it ever gets accidentally truncated.
  if [ -f "$zshrc_file" ] && [ "$(wc -l < "$zshrc_file")" -lt 40 ]; then
    @gitBin@ -C "$HOME/.config/zsh" checkout -- rcs/zshrc.zsh || true
  fi

  if [ -f "$zshrc_file" ] && grep -q '/Users/stephane\.lacoin/.local/share/pnpm' "$zshrc_file"; then
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/zshrc.zsh.XXXXXX")"
    sed 's|/Users/stephane\.lacoin/.local/share/pnpm|$HOME/.local/share/pnpm|g' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
  fi

  # Keep managed shell customizations in a dedicated part file and source it
  # from zshrc. This avoids reconstructing the entire zshrc and protects prompt
  # and plugin sections owned by the zdotdir repository.
  if [ -f "$zshrc_file" ]; then
    local zshrc_part_file="$HOME/.config/zsh/.zshrc.part.zsh"
    local source_begin_marker="# BEGIN nix-darwin-home sourced part"
    local source_end_marker="# END nix-darwin-home sourced part"
    local source_begin_count
    local source_end_count

    local tmp_part_file
    tmp_part_file="$(mktemp "${TMPDIR:-/tmp}/zshrc.part.zsh.XXXXXX")"
    {
      printf '%s\n' '# Managed by nix-darwin-home (do not edit manually).'
      printf '%s\n' ''
      printf '%s\n' '# Load home Flox environment early for interactive workflows.'
      printf '%s\n' 'if command -v flox >/dev/null 2>&1 && [ -z "${NIX_DARWIN_HOME_FLOX_LOADED:-}" ]; then'
      printf '%s\n' '  typeset -g NIX_DARWIN_HOME_FLOX_LOADED=1'
      printf '%s\n' '  if [ -n "${NIX_DARWIN_HOME_FLOX_ENV_DIR:-}" ] && [ -d "${NIX_DARWIN_HOME_FLOX_ENV_DIR}/.flox" ]; then'
      printf '%s\n' '    source <(flox activate --dir "${NIX_DARWIN_HOME_FLOX_ENV_DIR}") || true'
      printf '%s\n' '  elif [ -d "/var/lib/git/nxmatic/nix-darwin-home/.flox" ]; then'
      printf '%s\n' '    source <(flox activate --dir "/var/lib/git/nxmatic/nix-darwin-home") || true'
      printf '%s\n' '  elif [ -d "/Volumes/Git Worktree Store/nxmatic/nix-darwin-home/.flox" ]; then'
      printf '%s\n' '    source <(flox activate --dir "/Volumes/Git Worktree Store/nxmatic/nix-darwin-home") || true'
      printf '%s\n' '  fi'
      printf '%s\n' 'fi'
      printf '%s\n' ''
      printf '%s\n' '# Normalize PATH after plugin mutations.'
      printf '%s\n' 'typeset -U path'
      printf '%s\n' 'path=( ${path:#/Users/stephane.lacoin/*} )'
      printf '%s\n' 'path=( "$HOME/.local/bin" "$HOME/.local/share/pnpm" "$HOME/.local/opt/lima-vm/bin" "$HOME/.nix-profile/bin" /run/wrappers/bin /run/current-system/sw/bin "/etc/profiles/per-user/$USER/bin" "${path[@]}" )'
      printf '%s\n' 'export PATH="${(j/:/)path}"'
    } > "$tmp_part_file"
    mv "$tmp_part_file" "$zshrc_part_file"

    source_begin_count="$(grep -cF "$source_begin_marker" "$zshrc_file" || true)"
    source_end_count="$(grep -cF "$source_end_marker" "$zshrc_file" || true)"

    if [ "$source_begin_count" != "$source_end_count" ]; then
      echo "warning: sourced-part markers are imbalanced in $zshrc_file; skipping source-hook update" >&2
      return 0
    fi

    if [ "$source_begin_count" -eq 0 ]; then
      {
        printf '\n%s\n' "$source_begin_marker"
        printf '%s\n' '[[ -f "$HOME/.config/zsh/.zshrc.part.zsh" ]] && source "$HOME/.config/zsh/.zshrc.part.zsh"'
        printf '%s\n' "$source_end_marker"
      } >> "$zshrc_file"
    fi
  fi
}

activation_run "@activationTag@" main "$@"
