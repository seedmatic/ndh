# shellcheck disable=all

: "ssh agent settings"
# keychain integration is initialized by platform shell init; keep this
# block status-safe here to avoid rc startup leaking non-zero status.
true

__nxmatic_is_agent_vscode_terminal=0
if [[ "${TERM_PROGRAM:-}" == "vscode" ]] && {
  [[ "${VSCODE_PREVENT_SHELL_HISTORY:-}" == "1" ]] &&
  [[ ":${PATH}:" == *":$HOME/Library/Application Support/Code - Insiders/User/globalStorage/github.copilot-chat/debugCommand:"* ]];
}; then
  __nxmatic_is_agent_vscode_terminal=1
fi

__nxmatic_use_minimal_startup=0
if [[ "$__nxmatic_is_agent_vscode_terminal" == "1" ]]; then
  __nxmatic_use_minimal_startup=1
fi

# Reattach stdout/stderr early in Copilot-owned terminals before any prompt
# or plugin code can emit to stale instant-prompt descriptors.
if [[ -o interactive && "$__nxmatic_is_agent_vscode_terminal" == "1" ]]; then
  if [[ -w /dev/fd/10 ]]; then
    exec >/dev/fd/10 2>&1
  elif [[ -w /dev/tty ]]; then
    exec >/dev/tty 2>&1
  fi
fi

# zsh defines a `log` builtin (math function helper namespace) that can shadow
# user commands/aliases named `log`. Disable it when present so `log` can be
# used as a normal command name in interactive shells.
__nxmatic_log_whence="$(whence -w log 2>/dev/null || true)"
if [[ "$__nxmatic_log_whence" == *builtin* ]]; then
  disable log >/dev/null 2>&1 || true
fi
unset __nxmatic_log_whence

: "vscode settings"
# Only manually source if VS Code hasn't already injected the integration.
if [[ "$TERM_PROGRAM" == "vscode" && -z "$VSCODE_INJECTION" ]]; then
  # Agent-owned terminals (used by Copilot debug/hidden command execution)
  # are sensitive to duplicate/manual integration sourcing. Skip manual
  # sourcing there and let VS Code manage integration itself.
  if [[ "$__nxmatic_is_agent_vscode_terminal" == "1" ]]; then
    true
  else
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
fi

: "and my own stuff"
# Agent-owned hidden terminals are prone to p10k instant-prompt FD leaks
# (stdout/stderr left on p10k temp file). Disable instant prompt here and let
# normal prompt init run after startup.
if [[ "$__nxmatic_is_agent_vscode_terminal" == "1" ]]; then
  # Agent terminal safety: avoid parent-shell exit on non-zero status when
  # command exercises intentionally probe failures.
  unsetopt ERR_EXIT NO_UNSET PIPE_FAIL 2>/dev/null || true
  set +e +u 2>/dev/null || true

  # Optional diagnostics for troubleshooting hidden terminal state.
  if [[ "${NDH_AGENT_TERMINAL_DEBUG:-0}" == "1" ]]; then
    echo 'agent-terminal strict opts now:'
    (setopt | grep -E '^(err_exit|no_unset|pipe_fail)$' || echo 'none')
  fi

  typeset -g POWERLEVEL9K_INSTANT_PROMPT=off
fi

__nxmatic_zshrc_status=0
if [[ "$__nxmatic_use_minimal_startup" == "0" && -r "$ZDOTDIR/rcs/zshrc.zsh" ]]; then
  source "$ZDOTDIR/rcs/zshrc.zsh" || __nxmatic_zshrc_status=$?
fi

# Safety net: if stdout/stderr are still redirected to p10k instant prompt
# temp file after zshrc startup, reattach both streams to the active TTY.
if [[ -o interactive && "$__nxmatic_is_agent_vscode_terminal" == "1" ]]; then
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
fi

# In Copilot/agent-owned VS Code terminals, force a simple stable prompt and
# ensure this hook runs after theme hooks (e.g. powerlevel10k).
# Keep the user's regular interactive terminals on their preferred prompt.
if [[ "$__nxmatic_is_agent_vscode_terminal" == "1" ]]; then
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
unset __nxmatic_use_minimal_startup
unset __nxmatic_is_agent_vscode_terminal
true