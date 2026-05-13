#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @nixBashTrampoline@

LOG_TAG=@logTag@

# Warn-only post-flight assertion.  Runs every check independently and
# surfaces all failures to the journal so the operator sees the full
# picture, not just the first symptom.  Always exits 0, so this unit
# can never drag sshd or any dependent service into a failed state —
# a misconfigured user authorized_keys pipeline must not prevent root
# emergency SSH login, which is the operator's only way in to diagnose
# the underlying enrichment/extraction failure.
main() {
  auth_file="@authorizedKeysFile@"
  expected_pub="@expectedPublicKeyFile@"
  expected_user="@profileUserName@"

  local findings=0

  if [[ ! -r "$expected_pub" ]]; then
    logger -p auth.warning -t "$LOG_TAG" "missing expected public key file: ${expected_pub} (user=${expected_user}) — check ssh-keys-enrichment + ssh-extract-keys"
    findings=$((findings + 1))
  fi

  if [[ ! -r "$auth_file" ]]; then
    logger -p auth.warning -t "$LOG_TAG" "missing authorized keys file: ${auth_file} (user=${expected_user})"
    findings=$((findings + 1))
  fi

  local expected_blob=""
  if [[ -r "$expected_pub" ]]; then
    expected_blob="$(awk '{print $2}' "$expected_pub" | head -n1)"
    if [[ -z "$expected_blob" ]]; then
      logger -p auth.warning -t "$LOG_TAG" "could not parse key blob from: ${expected_pub}"
      findings=$((findings + 1))
    fi
  fi

  # Only run the match check when both inputs are actually available —
  # otherwise the findings above already describe the failure mode and
  # grep would just add noise.
  if [[ -r "$auth_file" && -n "$expected_blob" ]]; then
    if ! grep -Fq "$expected_blob" "$auth_file"; then
      logger -p auth.warning -t "$LOG_TAG" "authorized key mismatch: expected key from ${expected_pub} not present in ${auth_file} for user=${expected_user}"
      findings=$((findings + 1))
    fi
  fi

  if [[ "$findings" -eq 0 ]]; then
    logger -p auth.info -t "$LOG_TAG" "authorized key check passed for user=${expected_user} file=${auth_file}"
  else
    logger -p auth.warning -t "$LOG_TAG" "authorized key check completed with ${findings} finding(s) for user=${expected_user} — see prior warnings; not blocking sshd"
  fi
}

ndh::logger:command:run "@logTag@" main "$@"
