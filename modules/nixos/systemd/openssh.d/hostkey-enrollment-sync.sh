#!/usr/bin/env bash
# @codebase
set -euo pipefail

LOGGER=@loggerBin@/bin/logger
LOG_TAG=@logTag@
SSH_BIN=@sshBin@/bin/ssh
SSH_KEYGEN=@sshKeygen@/bin/ssh-keygen
YQ_BIN=@yqBin@/bin/yq

STATE_DIR=/run/nxmatic/ssh
MARKER_FILE=${STATE_DIR}/hostkey-enrollment-required
DETAILS_FILE=${STATE_DIR}/hostkey-enrollment-required.details
SUCCESS_FILE=${STATE_DIR}/hostkey-enrollment-sync.success
FAIL_FILE=${STATE_DIR}/hostkey-enrollment-sync.failure
SECRET_KEYS_YAML=@runtimeSecretsKeysYaml@
# Canonical private client identity lives under ssh-keys (per-user secrets).
# Public keys and host cert artifacts belong under ssh-system-keys.
CANONICAL_IDENTITY_FILE=@clientPrivateSource@
CANONICAL_IDENTITY_CERT=@clientUserCertSource@
TRANSIENT_IDENTITY_DIR=${STATE_DIR}/identity
TRANSIENT_IDENTITY_FILE=${TRANSIENT_IDENTITY_DIR}/rdp-host

mkdir -p "$STATE_DIR"
rm -f "$SUCCESS_FILE" "$FAIL_FILE"

if [ ! -f "$MARKER_FILE" ]; then
  "$LOGGER" -p auth.info -t "$LOG_TAG" "marker not present; nothing to sync"
  exit 0
fi

remote_host="${NDH_RDP_HOST:-${NDH_VZ_HOST:-@fallbackHost@}}"
remote_user="${NDH_ENROLL_REMOTE_USER:-@remoteUser@}"
remote_repo="${NDH_ENROLL_REMOTE_REPO:-@remoteRepo@}"
guest_name="${NDH_VZ_GUEST:-@guestName@}"
vm_name="${NDH_ENROLL_VM_NAME:-nerd-${guest_name}}"

if [[ "$remote_host" != *.* ]]; then
  remote_host="${remote_host}.local"
fi

identity_file="$CANONICAL_IDENTITY_FILE"
identity_cert_file="$CANONICAL_IDENTITY_CERT"

ensure_runtime_identity_from_secret() {
  local key_name=rdp-host
  local secret_private
  local secret_public
  local secret_user_cert

  if [ -s "$identity_file" ]; then
    return 0
  fi

  if [ ! -s "$SECRET_KEYS_YAML" ]; then
    "$LOGGER" -p auth.warning -t "$LOG_TAG" "cannot bootstrap runtime identity: missing $SECRET_KEYS_YAML"
    return 1
  fi

  secret_private="$($YQ_BIN -r ".profiles.committed.\"${key_name}\".private // \"\"" "$SECRET_KEYS_YAML")"
  if [ -z "$secret_private" ]; then
    "$LOGGER" -p auth.warning -t "$LOG_TAG" "cannot bootstrap runtime identity: missing .profiles.committed.${key_name}.private"
    return 1
  fi

  secret_public="$($YQ_BIN -r ".profiles.committed.\"${key_name}\".public // \"\"" "$SECRET_KEYS_YAML")"
  secret_user_cert="$($YQ_BIN -r ".profiles.committed.\"${key_name}\".certificates | (to_entries | map(.value.\"ssh-user\" // empty) | map(select(. != \"\")) | .[0]) // \"\"" "$SECRET_KEYS_YAML" 2>/dev/null || true)"

  install -d -m 700 "$TRANSIENT_IDENTITY_DIR"
  umask 077
  printf '%s\n' "$secret_private" > "$TRANSIENT_IDENTITY_FILE"
  chmod 600 "$TRANSIENT_IDENTITY_FILE"
  identity_file="$TRANSIENT_IDENTITY_FILE"

  if [ -n "$secret_public" ]; then
    printf '%s\n' "$secret_public" > "${TRANSIENT_IDENTITY_FILE}.pub"
    chmod 644 "${TRANSIENT_IDENTITY_FILE}.pub"
  else
    "$SSH_KEYGEN" -y -f "$TRANSIENT_IDENTITY_FILE" > "${TRANSIENT_IDENTITY_FILE}.pub"
    chmod 644 "${TRANSIENT_IDENTITY_FILE}.pub"
  fi

  if [ -n "$secret_user_cert" ]; then
    printf '%s\n' "$secret_user_cert" > "${TRANSIENT_IDENTITY_FILE}-cert.pub"
    chmod 644 "${TRANSIENT_IDENTITY_FILE}-cert.pub"
    identity_cert_file="${TRANSIENT_IDENTITY_FILE}-cert.pub"
  else
    identity_cert_file=""
  fi

  "$LOGGER" -p auth.notice -t "$LOG_TAG" "bootstrapped transient runtime SSH identity from ${SECRET_KEYS_YAML} key=${key_name}"
}

if [ ! -s "$identity_file" ]; then
  ensure_runtime_identity_from_secret || true
fi

if [ ! -s "$identity_file" ]; then
  touch "$FAIL_FILE"
  "$LOGGER" -p auth.err -t "$LOG_TAG" "missing runtime identity file for remote enrollment: canonical=${CANONICAL_IDENTITY_FILE} fallback_yaml=${SECRET_KEYS_YAML}"
  exit 1
fi

if [ -z "$identity_cert_file" ] && [ -s "$CANONICAL_IDENTITY_CERT" ]; then
  identity_cert_file="$CANONICAL_IDENTITY_CERT"
fi

if ! command -v "$SSH_BIN" >/dev/null 2>&1; then
  touch "$FAIL_FILE"
  "$LOGGER" -p auth.err -t "$LOG_TAG" "ssh binary not available: $SSH_BIN"
  exit 1
fi

# Keep remote invocation strict enough for automation while allowing first-contact host enrollment.
ssh_opts=(
  -o BatchMode=yes
  -o ConnectTimeout=10
  -o StrictHostKeyChecking=accept-new
  -o IdentitiesOnly=yes
  -i "$identity_file"
)

if [ -n "$identity_cert_file" ] && [ -s "$identity_cert_file" ]; then
  ssh_opts+=(
    -o CertificateFile="$identity_cert_file"
  )
fi

remote_cmd="set -euo pipefail; cd '$remote_repo'; chmod +x modules/nixos/ssh-keys.d/sync-vm-hostkey-keys-yaml.sh modules/nixos/ssh-keys.d/verify-vm-hostkey-from-sops.sh modules/nixos/ssh-keys.d/enroll-vm-hostkey-into-sops.sh; COPILOT_XTRACE=0 modules/nixos/ssh-keys.d/sync-vm-hostkey-keys-yaml.sh --vm '$vm_name' --guest '$guest_name' --profile committed --secrets-file modules/home-manager/ssh.d/keys.yaml"

if "$SSH_BIN" "${ssh_opts[@]}" "${remote_user}@${remote_host}" "$remote_cmd"; then
  rm -f "$MARKER_FILE" "$DETAILS_FILE"
  touch "$SUCCESS_FILE"
  "$LOGGER" -p auth.notice -t "$LOG_TAG" "remote hostkey enrollment sync succeeded via ${remote_user}@${remote_host} vm=${vm_name} guest=${guest_name}"
  exit 0
fi

touch "$FAIL_FILE"
"$LOGGER" -p auth.err -t "$LOG_TAG" "remote hostkey enrollment sync failed via ${remote_user}@${remote_host} vm=${vm_name} guest=${guest_name}"
exit 1
