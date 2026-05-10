#!/usr/bin/env bash
# @codebase
# AuthorizedPrincipalsCommand implementation that reads a pre-extracted
# principals input file generated at activation time.
#
# Input format:
#   YAML document with `.principals` as sequence/map, generated at activation.
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

  INPUT_FILE="@principalsInputPath@"

  if [[ ! -r "$INPUT_FILE" ]]; then
    echo "authorized principals input not readable at $INPUT_FILE; falling back to USER_NAME" >&2
    echo "$USER_NAME"
    exit 0
  fi

  USER_NAME=$USER_NAME yq eval-all --from-file=<( cat <<'EoF' | cut -c 5-
      [
        (
          .principals // []
          | select(tag == "!!seq")
          | .[]
        ),
        (
          .principals // {}
          | select(tag == "!!map")
          | keys
          | .[]
        )
      ] + [ env(USER_NAME) ]
      | map(select(. != null and . != ""))
      | sort
      | unique
      | .[]
EoF
  ) "$INPUT_FILE" || true
}

ndh::logger:command:run ssh.authorized-principals-command main "$@"

