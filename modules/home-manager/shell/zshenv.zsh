# ensure we're loading the rcs files

declare -g ZDOTDIR=${ZDOTDIR:-${0:a:h}/.config/zsh}

# redirect stderr and trace sourced files (lsof -p $$ | grep zshenv)

[[ -n "$ZDOTDEBUG" ]] &&
    function {
	source $ZDOTDIR/functions/**/zsh_stderr(N) open zshenv &&
	    setopt source_trace xtrace
    }

# source rcs zshenv

source $ZDOTDIR/rcs/zshenv.zsh
