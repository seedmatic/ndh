#!/usr/bin/env bash
# @codebase
# Print authorized SSH public keys aggregated from group-based key files.
# Invoked as: ssh-group-authorized-keys <username>
set -euo pipefail
PATH="/run/wrappers/bin:/run/current-system/sw/bin"
USER_NAME="${1:-}"
if [[ -z "${USER_NAME}" ]]; then
  exit 1
fi
DIR="/etc/ssh/group-authorized_keys.d"
[[ -d "$DIR" ]] || exit 0
for group in $USER_NAME $( id -nG "$USER_NAME" ); do
  FILEPATH="${DIR}/${group}"
  [[ -f "$FILEPATH" && -r "$FILEPATH" ]] || continue
  cat "$FILEPATH"
done
exit 0
