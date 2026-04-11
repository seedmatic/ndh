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

# shellcheck disable=SC1091
source "@bashTrampoline@"
# shellcheck disable=SC1091
source "@logger@"

main() {
  USER_NAME="${1:-}"
  if [[ -z "$USER_NAME" ]]; then
    echo "missing user" >&2
    exit 1
  fi

  # Try /etc/ssh/keys.yaml first (system-wide, readable by sshd helper user)
  # Fall back to per-user runtime secret when available.
  KEYS_FILE="/etc/ssh/keys.yaml"

  if [[ ! -r "$KEYS_FILE" ]]; then
    KEYS_FILE="/run/secrets/${USER_NAME}-ssh-keys.yaml"
  fi

  if [[ ! -r "$KEYS_FILE" ]]; then
    # Fallback to groups
    {
      echo "$USER_NAME"
      id -nG "$USER_NAME" | tr ' ' '\n'
    } | sort -u
    return 0
  fi

  USER_NAME=$USER_NAME yq eval-all --from-file=<( cat <<'EoF' | cut -c 5-
      [
        (
          ..
          | select(has("principals"))
          | .principals
          | select(tag == "!!seq")
          | .[]
        ),
        (
          ..
          | select(has("principals"))
          | .principals
          | select(tag == "!!map")
          | .[]
        )
      ] + [ env(USER_NAME) ]
      | map(select(. != null and . != ""))
      | sort
      | unique
      | .[]
EoF
  ) "$KEYS_FILE" || true
}

ndh::logger:command:run ssh.authorized-principals-command main "$@"

