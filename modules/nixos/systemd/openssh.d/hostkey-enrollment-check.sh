#!/usr/bin/env bash
# @codebase
set -euo pipefail

LOGGER=@loggerBin@/bin/logger
SSH_KEYGEN=@sshKeygen@/bin/ssh-keygen
LOG_TAG=@logTag@

USER_PRIVATE_SOURCE_DIR=@userPrivateSourceDir@
USER_CA_SOURCE_DIR=@userCaSourceDir@
SYSTEM_HOST_KEY_PUB=@systemHostKeyPub@

STATE_DIR=/run/nxmatic/ssh
MARKER_FILE=${STATE_DIR}/hostkey-enrollment-required
DETAILS_FILE=${STATE_DIR}/hostkey-enrollment-required.details

mkdir -p "$STATE_DIR"
rm -f "$MARKER_FILE" "$DETAILS_FILE"

CLIENT_KEY_NAME=rdp-host
SERVER_KEY_NAME="$CLIENT_KEY_NAME"

if [ -n "${NDH_VZ_GUEST:-}" ]; then
  guest_key_name="vz-guest-${NDH_VZ_GUEST}"
  if [ -s "$USER_PRIVATE_SOURCE_DIR/$guest_key_name" ]; then
    SERVER_KEY_NAME="$guest_key_name"
  fi
fi

EXPECTED_PUB="${USER_CA_SOURCE_DIR}/${SERVER_KEY_NAME}.pub"
reason=""

fingerprint() {
  "$SSH_KEYGEN" -lf "$1" 2>/dev/null | awk '{print $2}'
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
  touch "$MARKER_FILE"
  {
    printf 'required=true\n'
    printf 'reason=%s\n' "$reason"
    printf 'server_key_name=%s\n' "$SERVER_KEY_NAME"
    printf 'expected_pub=%s\n' "$EXPECTED_PUB"
    printf 'system_host_key_pub=%s\n' "$SYSTEM_HOST_KEY_PUB"
    if [ -s "$EXPECTED_PUB" ]; then
      printf 'expected_fingerprint=%s\n' "$(fingerprint "$EXPECTED_PUB")"
    fi
    if [ -s "$SYSTEM_HOST_KEY_PUB" ]; then
      printf 'system_fingerprint=%s\n' "$(fingerprint "$SYSTEM_HOST_KEY_PUB")"
    fi
  } >"$DETAILS_FILE"
  "$LOGGER" -p auth.warning -t "$LOG_TAG" "enrollment required: reason=${reason} server_key=${SERVER_KEY_NAME} marker=${MARKER_FILE}"
else
  "$LOGGER" -p auth.info -t "$LOG_TAG" "host key aligned with secret key=${SERVER_KEY_NAME}"
fi
