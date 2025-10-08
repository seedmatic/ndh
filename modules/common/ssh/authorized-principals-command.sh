#!/usr/bin/env bash
# @codebase
# AuthorizedPrincipalsCommand implementation that derives principals from the
# generated keys.yaml (produced by ssh-generate-keys-yaml.sh) so that SSH user
# certificate signing principals and sshd AuthorizedPrincipals align.
#
# Fallback: if keys.yaml (or expected structure) is missing, emit Unix groups
# for the user (previous behavior) to avoid locking accounts out.
#
# Usage: authorized-principals-command <user>
set -euo pipefail
PATH="/run/wrappers/bin:/run/current-system/sw/bin"
USER_NAME="${1:-}"
if [[ -z "$USER_NAME" ]]; then
  echo "missing user" >&2
  exit 1
fi

KEYS_FILE="/Users/${USER_NAME}/.ssh/keys.yaml"
if [[ ! -r "$KEYS_FILE" ]]; then
  # Fallback to groups
  cat <<EoF
  $USER_NAME
  $( id -nG "$USER_NAME" | tr ' ' '\n' )
EoF
  exit 0
fi

yq '[.. | select(has("principals")) | .principals] | flatten | sort | unique | .[]' "$KEYS_FILE" 2>/dev/null

exit 0
