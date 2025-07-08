# shellcheck disable=all

echo "Loading Zsh environment..."

: ensure we're using the wrappers
path=( /run/wrappers/bin "${path[@]}" )

: ensure we\'re loading the rcs files
declare -g ZDOTDIR=${HOME}/.config/zsh

path=( /etc/profiles/per-user/nxmatic/bin /run/current-system/sw/bin "${path[@]}" )

# ZDOTDEBUG=true

: source rcs zshenv
source "$ZDOTDIR"/rcs/zshenv.zsh
