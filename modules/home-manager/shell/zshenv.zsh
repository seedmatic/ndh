# shellcheck disable=all

: ensure we\'re loading the wrappers and user bin directory with wrappers first
typeset -U path
path=( "$HOME/.local/bin" "$HOME/.local/share/pnpm" "$HOME/.local/opt/lima-vm/bin" "$HOME/.nix-profile/bin" /run/wrappers/bin /run/current-system/sw/bin "/etc/profiles/per-user/$USER/bin" "${path[@]}" )

: ensure we always have a TERM
declare -g TERM=xterm-256color

: ensure we\'re loading the rcs files
declare -g ZDOTDIR=${HOME}/.config/zsh

: Load the zshenv file
# ZDOTDEBUG=true

source "$ZDOTDIR"/rcs/zshenv.zsh
