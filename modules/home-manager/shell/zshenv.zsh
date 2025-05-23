# shellcheck disable=all

: ensure we\'re loading the rcs files
declare -g ZDOTDIR=${HOME}/.config/zsh

path=( /etc/profiles/per-user/nxmatic/bin /run/current-system/sw/bin "${path[@]}" )

: redirect stderr and trace sourced files \( lsof -p $$ | grep zshenv \)
[[ -n "$ZDOTDEBUG" ]] &&
    function {
	    source "$ZDOTDIR"/functions/zsh_stderr(N) open zshenv &&
	    setopt source_trace xtrace
    }

: source rcs zshenv
source "$ZDOTDIR"/rcs/zshenv.zsh d
