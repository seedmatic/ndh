# shellcheck disable=all

: ensure we\'re loading the wrappers and user bin directory at first
path=( /run/wrappers/bin "/etc/profiles/per-user/$USER/bin" /run/current-system/sw/bin "${path[@]}" )

: ensure we always have a TERM
declare -g TERM=xterm-256color

: ensure we\'re loading the rcs files
declare -g ZDOTDIR=${HOME}/.config/zsh

: Load the zshenv file
# ZDOTDEBUG=true

source "$ZDOTDIR"/rcs/zshenv.zsh
