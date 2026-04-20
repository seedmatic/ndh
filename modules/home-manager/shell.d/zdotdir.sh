source @nixBashTrampoline@

main() {
  set -euo pipefail

  export SSL_CERT_FILE="@caBundle@"
  export GIT_SSL_CAINFO="@caBundle@"
  export CURL_CA_BUNDLE="@caBundle@"

  if [ ! -r "$SSL_CERT_FILE" ]; then
    echo "error: CA bundle not readable: $SSL_CERT_FILE" >&2
    return 1
  fi

  if [ ! -d "$HOME/.config/zsh/.git" ]; then
    mkdir -p "$HOME/.config"
    git clone --depth=1 https://github.com/nxmatic/zdotdir.git "$HOME/.config/zsh"
  else
    git -C "$HOME/.config/zsh" pull --ff-only
  fi

  # Keep PNPM_HOME user-relative even if upstream zdotdir contains a stale
  # absolute path from a previous account migration.
  local zshrc_file="$HOME/.config/zsh/rcs/zshrc.zsh"

  # Guardrail: recover zshrc from git if it ever gets accidentally truncated.
  if [ -f "$zshrc_file" ] && [ "$(wc -l < "$zshrc_file")" -lt 40 ]; then
    git -C "$HOME/.config/zsh" checkout -- rcs/zshrc.zsh || true
  fi

  if [ -f "$zshrc_file" ] && grep -q '/Users/stephane\.lacoin/.local/share/pnpm' "$zshrc_file"; then
    local tmp_file
    tmp_file="$(mktemp "${TMPDIR:-/tmp}/zshrc.zsh.XXXXXX")"
    sed 's|/Users/stephane\.lacoin/.local/share/pnpm|$HOME/.local/share/pnpm|g' "$zshrc_file" > "$tmp_file"
    mv "$tmp_file" "$zshrc_file"
  fi

  # Guard Lima keychain bootstrap on hosts where ~/.lima/_config/user is absent
  # (e.g. NixOS guest). Keep keychain behavior when the key exists.
  local zlogin_file
  for zlogin_file in "$HOME/.config/zsh/rcs/zlogin.zsh" "$HOME/.config/zsh/.zlogin"; do
    if [ -f "$zlogin_file" ] && grep -qF 'source <( keychain --eval --quiet ~/.lima/_config/user )' "$zlogin_file"; then
      local tmp_zlogin
      tmp_zlogin="$(mktemp "${TMPDIR:-/tmp}/zlogin.zsh.XXXXXX")"
      awk '
        /source <\( keychain --eval --quiet ~\/\.lima\/_config\/user \)/ {
          print "if [ -r \"$HOME/.lima/_config/user\" ]; then"
          print "  source <( keychain --eval --quiet ~/.lima/_config/user )"
          print "fi"
          next
        }
        { print }
      ' "$zlogin_file" > "$tmp_zlogin"
      mv "$tmp_zlogin" "$zlogin_file"
    fi
  done

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
    cat > "$tmp_part_file" <<'EOF'
# Managed by nix-darwin-home (do not edit manually).

# Load home Flox environment early for interactive workflows.
if command -v flox >/dev/null 2>&1 && [ -z "${NIX_DARWIN_HOME_FLOX_LOADED:-}" ]; then
  typeset -g NIX_DARWIN_HOME_FLOX_LOADED=1
  if [ -n "${NIX_DARWIN_HOME_FLOX_ENV_DIR:-}" ] && [ -d "${NIX_DARWIN_HOME_FLOX_ENV_DIR}/.flox" ]; then
    source <(flox activate --dir "${NIX_DARWIN_HOME_FLOX_ENV_DIR}") || true
  elif [ -d "/var/lib/git/nxmatic/nix-darwin-home/.flox" ]; then
    source <(flox activate --dir "/var/lib/git/nxmatic/nix-darwin-home") || true
  elif [ -d "/Volumes/Git Worktree Store/nxmatic/nix-darwin-home/.flox" ]; then
    source <(flox activate --dir "/Volumes/Git Worktree Store/nxmatic/nix-darwin-home") || true
  fi
fi

# Normalize PATH after plugin mutations.
typeset -U path
path=( ${path:#/Users/stephane.lacoin/*} )
path=( "$HOME/.local/bin" "$HOME/.local/share/pnpm" "$HOME/.local/opt/lima-vm/bin" "$HOME/.nix-profile/bin" /run/wrappers/bin /run/current-system/sw/bin "/etc/profiles/per-user/$USER/bin" "${path[@]}" )
export PATH="${(j/:/)path}"

# In Copilot/agent-owned VS Code terminals, force a simple stable prompt and
# ensure this hook runs after theme hooks (e.g. powerlevel10k).
# Keep the user's regular interactive terminals on their preferred prompt.
if [[ "${TERM_PROGRAM:-}" == "vscode" ]] && \
   [[ "${VSCODE_PREVENT_SHELL_HISTORY:-}" == "1" ]]; then
  # Reattach stdout/stderr early for agent terminals before prompt hooks.
  if [[ -w /dev/fd/10 ]]; then
    exec >/dev/fd/10 2>&1
  elif [[ -w /dev/tty ]]; then
    exec >/dev/tty 2>&1
  fi

  # Disable powerlevel10k prompt rendering in agent-owned terminals.
  precmd_functions=(${precmd_functions:#_p9k_precmd})
  if typeset -f _p9k_precmd >/dev/null 2>&1; then
    functions[_p9k_precmd]='return 0'
  fi

  nxmatic_safe_prompt() {
    PROMPT="%n@%m:%~ %# "
    RPROMPT=""
  }
  precmd_functions=(${precmd_functions:#nxmatic_safe_prompt} nxmatic_safe_prompt)
  nxmatic_safe_prompt

  # Safety net: if stdout/stderr still point at p10k instant prompt temp
  # file, reattach both streams to a live terminal descriptor.
  __nxmatic_fd1_target="$(/bin/readlink /dev/fd/1 2>/dev/null || true)"
  __nxmatic_fd2_target="$(/bin/readlink /dev/fd/2 2>/dev/null || true)"
  if [[ "$__nxmatic_fd1_target" == *p10k-instant-prompt-output* || "$__nxmatic_fd2_target" == *p10k-instant-prompt-output* ]]; then
    if [[ -w /dev/fd/10 ]]; then
      exec >/dev/fd/10 2>&1
    elif [[ -w /dev/tty ]]; then
      exec >/dev/tty 2>&1
    fi
  fi
  unset __nxmatic_fd1_target __nxmatic_fd2_target
else
  # Keep powerlevel10k instant prompt happy when active in user terminals.
  (( ! ${+functions[p10k]} )) || p10k finalize
fi
true
EOF
    mv "$tmp_part_file" "$zshrc_part_file"

    source_begin_count="$(grep -cF "$source_begin_marker" "$zshrc_file" || true)"
    source_end_count="$(grep -cF "$source_end_marker" "$zshrc_file" || true)"

    if [ "$source_begin_count" != "$source_end_count" ]; then
      echo "warning: sourced-part markers are imbalanced in $zshrc_file; skipping source-hook update" >&2
      return 0
    fi

    if [ "$source_begin_count" -eq 0 ]; then
      echo >> "$zshrc_file"
      cat >> "$zshrc_file" <<'EOF'
# BEGIN nix-darwin-home sourced part
[[ -f "$HOME/.config/zsh/.zshrc.part.zsh" ]] && source "$HOME/.config/zsh/.zshrc.part.zsh"
# END nix-darwin-home sourced part
EOF
    fi
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"

if [ ! -r "$HOME/.config/zsh/rcs/zshenv.zsh" ]; then
  echo "error: zdotdir sync did not produce $HOME/.config/zsh/rcs/zshenv.zsh" >&2
  exit 1
fi
