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
USER_NAME="${1:-}"
if [[ -z "$USER_NAME" ]]; then
  echo "missing user" >&2
  exit 1
fi

KEYS_FILE="/Users/${USER_NAME}/.ssh/keys.yaml"
if [[ ! -r "$KEYS_FILE" ]]; then
  # Fallback to groups
  id -nG "$USER_NAME" | tr ' ' '\n'
  exit 0
fi

# Extract principals arrays from keys: entries; supports two YAML shapes:
# 1. legacy: keyName: { principals: [ a, b ] }
# 2. consolidated under keys: root key.

if command -v yq >/dev/null 2>&1; then
  # yq-go compatible expression: accumulate unique principals
  yq '.["keys"] // . | .. | select(has("principals")) | .principals[]' "$KEYS_FILE" 2>/dev/null | \
    awk 'NF' | sort -u
else
  # Minimal grep/awk fallback (best effort)
  grep -E '^\s*principals:' "$KEYS_FILE" | sed -E 's/.*\[(.*)\].*/\1/' | tr ',' '\n' | sed 's/^ *//;s/ *$//' | awk 'NF' | sort -u
fi

exit 0
