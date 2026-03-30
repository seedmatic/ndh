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
DIR="@authorizedKeysDir@"
[[ -d "$DIR" ]] || exit 0

groups=("$USER_NAME")
while IFS= read -r group; do
  [[ -n "$group" ]] || continue
  groups+=("$group")
done < <(id -nG "$USER_NAME" | tr ' ' '\n')

for group in "${groups[@]}"; do
  FILEPATH="${DIR}/${group}"
  [[ -f "$FILEPATH" && -r "$FILEPATH" ]] || continue
  cat "$FILEPATH"
done | awk '!seen[$0]++'
exit 0
