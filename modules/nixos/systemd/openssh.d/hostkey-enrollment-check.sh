#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@

LOG_TAG=@logTag@

USER_PRIVATE_SOURCE_DIR=@userPrivateSourceDir@
USER_CA_SOURCE_DIR=@userCaSourceDir@
SYSTEM_HOST_KEY_PUB=@systemHostKeyPub@

STATE_DIR=/run/ndh/ssh
STATE_FILE=${STATE_DIR}/hostkey-enrollment-state.yaml

main() {
  mkdir -p "$STATE_DIR"

  CLIENT_KEY_NAME=@clientKeyName@
  SERVER_KEY_NAME="$CLIENT_KEY_NAME"

  EXPECTED_PUB="${USER_CA_SOURCE_DIR}/${SERVER_KEY_NAME}.pub"
  reason=""

  fingerprint() {
    ssh-keygen -lf "$1" 2>/dev/null | awk '{print $2}'
  }

  if [ ! -s "$EXPECTED_PUB" ]; then
    reason="missing_expected_secret_key"
  elif [ ! -s "$SYSTEM_HOST_KEY_PUB" ]; then
    reason="missing_system_hostkey"
  else
    expected_fp="$(fingerprint "$EXPECTED_PUB")"
    system_fp="$(fingerprint "$SYSTEM_HOST_KEY_PUB")"
    if [ -z "$expected_fp" ] || [ -z "$system_fp" ]; then
      reason="fingerprint_unavailable"
    elif [ "$expected_fp" != "$system_fp" ]; then
      reason="hostkey_mismatch"
    fi
  fi

  if [ -n "$reason" ]; then
    required=true
    logger -p auth.warning -t "$LOG_TAG" "enrollment required: reason=${reason} server_key=${SERVER_KEY_NAME} state=${STATE_FILE}"
  else
    required=false
    reason="aligned"
    logger -p auth.info -t "$LOG_TAG" "host key aligned with secret key=${SERVER_KEY_NAME}"
  fi

  expected_fp=""
  system_fp=""
  if [ -s "$EXPECTED_PUB" ]; then
    expected_fp="$(fingerprint "$EXPECTED_PUB")"
  fi
  if [ -s "$SYSTEM_HOST_KEY_PUB" ]; then
    system_fp="$(fingerprint "$SYSTEM_HOST_KEY_PUB")"
  fi

  updated_at="$(date -Iseconds)"
  tmp_state="$(mktemp)"
  env \
    REQUIRED="$required" \
    REASON="$reason" \
    SERVER_KEY_NAME="$SERVER_KEY_NAME" \
    EXPECTED_PUB="$EXPECTED_PUB" \
    SYSTEM_HOST_KEY_PUB="$SYSTEM_HOST_KEY_PUB" \
    EXPECTED_FP="$expected_fp" \
    SYSTEM_FP="$system_fp" \
    UPDATED_AT="$updated_at" \
    yq --null-input eval '
      {
        required: (strenv(REQUIRED) == "true"),
        reason: strenv(REASON),
        server_key_name: strenv(SERVER_KEY_NAME),
        expected_pub: strenv(EXPECTED_PUB),
        system_host_key_pub: strenv(SYSTEM_HOST_KEY_PUB),
        expected_fingerprint: strenv(EXPECTED_FP),
        system_fingerprint: strenv(SYSTEM_FP),
        updated_at: strenv(UPDATED_AT)
      }
    ' >"$tmp_state"

  install -m 0664 "$tmp_state" "$STATE_FILE"
  rm -f "$tmp_state"
}

ndh::logger:command:run "@logTag@" main "$@"
