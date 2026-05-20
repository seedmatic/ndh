# shellcheck disable=all

: PATH is rendered by home-manager from modules/home-manager/shell.nix
: '(home.sessionPath = coreShellPath)'. Just deduplicate after plugin
: mutations \(typeset -U path\) — do not rebuild the list here.
typeset -U path

: ensure we always have a TERM
declare -g TERM=xterm-256color

: canonical TLS variables are set via Home Manager sessionVariables.
: fallback only if session vars are unavailable in this shell invocation.
if [[ -z "${SSL_CERT_FILE:-}" ]]; then
  if [[ -r /etc/ssl/certs/ca-bundle.crt ]]; then
    declare -g SSL_CERT_FILE=/etc/ssl/certs/ca-bundle.crt
  elif [[ -r /etc/static/ssl/certs/ca-bundle.crt ]]; then
    declare -g SSL_CERT_FILE=/etc/static/ssl/certs/ca-bundle.crt
  elif [[ -r /etc/ssl/cert.pem ]]; then
    declare -g SSL_CERT_FILE=/etc/ssl/cert.pem
  fi
fi

if [[ -n "${SSL_CERT_FILE:-}" ]]; then
  declare -g NIX_SSL_CERT_FILE="${NIX_SSL_CERT_FILE:-$SSL_CERT_FILE}"
  declare -g GIT_SSL_CAINFO="${GIT_SSL_CAINFO:-$SSL_CERT_FILE}"
  declare -g CURL_CA_BUNDLE="${CURL_CA_BUNDLE:-$SSL_CERT_FILE}"
fi

: ensure we\'re loading the rcs files
declare -g ZDOTDIR=${HOME}/.config/zsh

: Load the zshenv file
# ZDOTDEBUG=true

if [[ -r "$ZDOTDIR"/rcs/zshenv.zsh ]]; then
  source "$ZDOTDIR"/rcs/zshenv.zsh
fi
