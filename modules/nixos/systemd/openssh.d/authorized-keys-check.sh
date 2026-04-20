#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @nixBashTrampoline@

LOG_TAG=@logTag@

main() {
  auth_file="@authorizedKeysFile@"
  expected_pub="@expectedPublicKeyFile@"
  expected_user="@profileUserName@"

  if [[ ! -r "$expected_pub" ]]; then
    logger -p auth.err -t "$LOG_TAG" "missing expected public key file: ${expected_pub}"
    exit 1
  fi

  if [[ ! -r "$auth_file" ]]; then
    logger -p auth.err -t "$LOG_TAG" "missing authorized keys file: ${auth_file}"
    exit 1
  fi

  expected_blob="$(awk '{print $2}' "$expected_pub" | head -n1)"
  if [[ -z "$expected_blob" ]]; then
    logger -p auth.err -t "$LOG_TAG" "could not parse key blob from: ${expected_pub}"
    exit 1
  fi

  if ! grep -Fq "$expected_blob" "$auth_file"; then
    logger -p auth.err -t "$LOG_TAG" "authorized key mismatch: expected key from ${expected_pub} not present in ${auth_file} for user=${expected_user}"
    exit 1
  fi

  logger -p auth.info -t "$LOG_TAG" "authorized key check passed for user=${expected_user} file=${auth_file}"
}

ndh::logger:command:run "@logTag@" main "$@"
