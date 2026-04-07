#!/usr/bin/env bash
# @codebase
set -euo pipefail

LOG_TAG=@logTag@

STATE_DIR=/run/ndh/ssh
MARKER_FILE=${STATE_DIR}/hostkey-enrollment-required
DETAILS_FILE=${STATE_DIR}/hostkey-enrollment-required.details
SUCCESS_FILE=${STATE_DIR}/hostkey-enrollment-sync.success
FAIL_FILE=${STATE_DIR}/hostkey-enrollment-sync.failure
# Canonical private client identity lives under ssh-keys (per-user secrets).
# Public keys and host cert artifacts belong under ssh-authority.
CANONICAL_IDENTITY_FILE=@clientPrivateSource@
CANONICAL_IDENTITY_CERT=@clientUserCertSource@

mkdir -p "$STATE_DIR"
rm -f "$SUCCESS_FILE" "$FAIL_FILE"

if [ ! -f "$MARKER_FILE" ]; then
  logger -p auth.info -t "$LOG_TAG" "marker not present; nothing to sync"
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

if [ ! -s "$identity_file" ]; then
  touch "$FAIL_FILE"
  logger -p auth.err -t "$LOG_TAG" "missing canonical runtime identity file for remote enrollment: ${CANONICAL_IDENTITY_FILE}"
  exit 1
fi

if [ -z "$identity_cert_file" ] && [ -s "$CANONICAL_IDENTITY_CERT" ]; then
  identity_cert_file="$CANONICAL_IDENTITY_CERT"
fi

if ! command -v ssh >/dev/null 2>&1; then
  touch "$FAIL_FILE"
  logger -p auth.err -t "$LOG_TAG" "ssh binary not available"
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

if ssh "${ssh_opts[@]}" "${remote_user}@${remote_host}" "$remote_cmd"; then
  rm -f "$MARKER_FILE" "$DETAILS_FILE"
  touch "$SUCCESS_FILE"
  logger -p auth.notice -t "$LOG_TAG" "remote hostkey enrollment sync succeeded via ${remote_user}@${remote_host} vm=${vm_name} guest=${guest_name}"
  exit 0
fi

touch "$FAIL_FILE"
logger -p auth.err -t "$LOG_TAG" "remote hostkey enrollment sync failed via ${remote_user}@${remote_host} vm=${vm_name} guest=${guest_name}"
exit 1
