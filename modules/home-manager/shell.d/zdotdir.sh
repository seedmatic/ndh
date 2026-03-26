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

  # Ensure runtime PATH normalization exists in the active zdotdir zshrc.
  # This shell loads ~/.config/zsh/.zshrc (not ~/.zshrc when ZDOTDIR is set),
  # so keep the canonical Nix profile path and cleanup there.
  if [ -f "$zshrc_file" ]; then
    local flox_begin_marker="# BEGIN nix-darwin-home FLOX home env"
    local flox_end_marker="# END nix-darwin-home FLOX home env"
    local begin_marker="# BEGIN nix-darwin-home PATH normalize"
    local end_marker="# END nix-darwin-home PATH normalize"
    local flox_begin_count
    local flox_end_count
    local begin_count
    local end_count
    flox_begin_count="$(grep -cF "$flox_begin_marker" "$zshrc_file" || true)"
    flox_end_count="$(grep -cF "$flox_end_marker" "$zshrc_file" || true)"
    begin_count="$(grep -cF "$begin_marker" "$zshrc_file" || true)"
    end_count="$(grep -cF "$end_marker" "$zshrc_file" || true)"

    # Guardrail: avoid editing if markers are imbalanced/corrupt.
    if [ "$flox_begin_count" != "$flox_end_count" ]; then
      echo "warning: FLOX home env markers are imbalanced in $zshrc_file; skipping managed block update" >&2
      return 0
    fi

    # Guardrail: avoid editing if markers are imbalanced/corrupt.
    if [ "$begin_count" != "$end_count" ]; then
      echo "warning: PATH normalize markers are imbalanced in $zshrc_file; skipping managed block update" >&2
      return 0
    fi

    # Guardrail: keep a backup before managed in-place rewrites.
    cp "$zshrc_file" "$zshrc_file.bak.nix-darwin-home"

    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/zshrc.zsh.XXXXXX")"

    awk -v flox_begin="$flox_begin_marker" -v flox_end="$flox_end_marker" -v begin="$begin_marker" -v end="$end_marker" '
      $0 == flox_begin { skip = 1; next }
      $0 == flox_end   { skip = 0; next }
      $0 == begin      { skip = 1; next }
      $0 == end        { skip = 0; next }
      skip != 1   { print }
    ' "$zshrc_file" > "$tmp_file"

    local stripped_file
    stripped_file="$tmp_file"
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/zshrc.zsh.XXXXXX")"

    {
      printf '%s\n' "$flox_begin_marker"
      printf '%s\n' '# Load home Flox environment before the rest of zshrc.'
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
      printf '%s\n' "$flox_end_marker"
      printf '\n'
      printf '\n%s\n' "$begin_marker"
      printf '%s\n' '# Normalize PATH after plugin mutations.'
      printf '%s\n' 'typeset -U path'
      printf '%s\n' 'path=( ${path:#/Users/stephane.lacoin/*} )'
      printf '%s\n' 'path=( "$HOME/.local/bin" "$HOME/.local/share/pnpm" "$HOME/.local/opt/lima-vm/bin" "$HOME/.nix-profile/bin" /run/wrappers/bin /run/current-system/sw/bin "/etc/profiles/per-user/$USER/bin" "${path[@]}" )'
      printf '%s\n' 'export PATH="${(j/:/)path}"'
      printf '%s\n' "$end_marker"
      printf '\n'
      cat "$stripped_file"
    } > "$tmp_file"

    rm -f "$stripped_file"

    mv "$tmp_file" "$zshrc_file"
  fi
}

activation_run "@activationTag@" main "$@"
