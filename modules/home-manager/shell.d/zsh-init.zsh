# shellcheck disable=all

: "ssh agent settings"
# keychain integration is initialized by platform shell init; keep this
# block status-safe here to avoid rc startup leaking non-zero status.
true

: "vscode settings"
# Only manually source if VS Code hasn't already injected the integration.
if [[ "$TERM_PROGRAM" == "vscode" && -z "$VSCODE_INJECTION" ]]; then
  vscode_bin="$(command -v code-insiders || command -v code || true)"
  if [[ -n "$vscode_bin" ]]; then
    VSCODE_SHELL_INTEGRATION="$($vscode_bin --locate-shell-integration-path zsh 2>/dev/null)"
  else
    VSCODE_SHELL_INTEGRATION=""
  fi
  if [[ -n "$VSCODE_SHELL_INTEGRATION" && -f "$VSCODE_SHELL_INTEGRATION" ]]; then
    # Set the variable that the integration script expects when manually sourced.
    VSCODE_INJECTION=1
    USER_ZDOTDIR="$ZDOTDIR"
    builtin source "$VSCODE_SHELL_INTEGRATION"
    TERM=xterm-256color
  fi
fi

: "and my own stuff"
__nxmatic_zshrc_status=0
if [[ -r "$ZDOTDIR/rcs/zshrc.zsh" ]]; then
  source "$ZDOTDIR/rcs/zshrc.zsh" || __nxmatic_zshrc_status=$?
fi

# In Copilot/agent-owned VS Code terminals, force a simple stable prompt and
# ensure this hook runs after theme hooks (e.g. powerlevel10k).
# Keep the user's regular interactive terminals on their preferred prompt.
if [[ "${TERM_PROGRAM:-}" == "vscode" ]] && {
  [[ "${VSCODE_PREVENT_SHELL_HISTORY:-}" == "1" ]] ||
  [[ ":${PATH}:" == *":$HOME/Library/Application Support/Code - Insiders/User/globalStorage/github.copilot-chat/debugCommand:"* ]];
}; then
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
fi

# Fallback to a minimal prompt if external zshrc exits non-zero.
if [[ "$__nxmatic_zshrc_status" -ne 0 ]]; then
  print -u2 -- "warning: zshrc startup returned status $__nxmatic_zshrc_status; using simple prompt"
  PROMPT='%n@%m:%~ %# '
  RPROMPT=""
fi

# Normalize PATH after external zshrc/plugin mutations.
# Keep canonical Nix paths and remove stale foreign-home entries.
typeset -U path
path=( ${path:#/Users/stephane.lacoin/*} )
path=(
  "$HOME/.local/bin"
  "$HOME/.local/share/pnpm"
  "$HOME/.local/opt/lima-vm/bin"
  "$HOME/.nix-profile/bin"
  @linuxWrappersLine@
  /run/current-system/sw/bin
  "/etc/profiles/per-user/$USER/bin"
  "${path[@]}"
)
export PATH="${(j/:/)path}"

# Avoid autofs trigger on the first-level /net mountpoint, but allow
# completion once inside /net/<host>/...
zstyle ':completion:*:paths' ignored-patterns '/net'
zstyle ':completion:*:(cd|chdir|pushd|popd|ls):*' ignored-patterns '/net'

unset __nxmatic_zshrc_status
true