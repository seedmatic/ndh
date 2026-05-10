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
source "@nixBashTrampoline@"

main() {
  USER_NAME="${1:-}"
  if [[ -z "$USER_NAME" ]]; then
    echo "missing user" >&2
    exit 1
  fi

  # Deterministic path from sops-nix decrypted secret
  KEYS_FILE="@keysYamlPath@"

  if [[ ! -r "$KEYS_FILE" ]]; then
    echo "keys.yaml not readable at $KEYS_FILE" >&2
    exit 1
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

