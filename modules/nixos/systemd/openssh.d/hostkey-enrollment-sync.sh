#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @bashTrampoline@
# shellcheck disable=SC1091
source @logger@

LOG_TAG=@logTag@

main() {
  STATE_DIR=/run/ndh/ssh
  STATE_FILE=${STATE_DIR}/hostkey-enrollment-state.yaml
  # Canonical private client identity lives under ssh-keys (per-user secrets).
  # Public keys and host cert artifacts belong under ssh-authority.
  CANONICAL_IDENTITY_FILE=@clientPrivateSource@
  CANONICAL_IDENTITY_CERT=@clientUserCertSource@
  MANAGED_HOST_DOMAIN="${NDH_MANAGED_HOST_DOMAIN:-.local}"

  mkdir -p "$STATE_DIR"

  if [ ! -f "$STATE_FILE" ]; then
    logger -p auth.info -t "$LOG_TAG" "state file not present; nothing to sync"
    exit 0
  fi

  if ! yq eval -e '.required == true' "$STATE_FILE" >/dev/null 2>&1; then
    logger -p auth.info -t "$LOG_TAG" "state indicates no enrollment required; nothing to sync"
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

  is_managed_domain_host=0
  if [[ "$remote_host" == *"${MANAGED_HOST_DOMAIN}" ]]; then
    is_managed_domain_host=1
  fi

  identity_file="$CANONICAL_IDENTITY_FILE"
  identity_cert_file="$CANONICAL_IDENTITY_CERT"

  sync_started_at="$(date -Iseconds)"
  env NOW="$sync_started_at" yq eval -i '.last_sync.status = "running" | .last_sync.updated_at = strenv(NOW)' "$STATE_FILE"

  if [ ! -s "$identity_file" ]; then
    env NOW="$(date -Iseconds)" yq eval -i '.last_sync.status = "failed" | .last_sync.reason = "missing_identity_file" | .last_sync.updated_at = strenv(NOW)' "$STATE_FILE"
    logger -p auth.err -t "$LOG_TAG" "missing canonical runtime identity file for remote enrollment: ${CANONICAL_IDENTITY_FILE}"
    exit 1
  fi

  if [ -z "$identity_cert_file" ] && [ -s "$CANONICAL_IDENTITY_CERT" ]; then
    identity_cert_file="$CANONICAL_IDENTITY_CERT"
  fi

  if ! command -v ssh >/dev/null 2>&1; then
    env NOW="$(date -Iseconds)" yq eval -i '.last_sync.status = "failed" | .last_sync.reason = "ssh_binary_unavailable" | .last_sync.updated_at = strenv(NOW)' "$STATE_FILE"
    logger -p auth.err -t "$LOG_TAG" "ssh binary not available"
    exit 1
  fi

  # Keep remote invocation strict enough for automation while allowing first-contact host enrollment.
  ssh_opts=(
    -o BatchMode=yes
    -o ConnectTimeout=10
    -o IdentitiesOnly=yes
    -i "$identity_file"
  )

  if [[ "$is_managed_domain_host" == "1" ]]; then
    current_fp=""
    if scan_line="$(ssh-keyscan -T 5 -t ed25519 "$remote_host" 2>/dev/null | head -n1)" && [[ -n "$scan_line" ]]; then
      scan_tmp="$(mktemp)"
      printf '%s\n' "$scan_line" >"$scan_tmp"
      current_fp="$(ssh-keygen -lf "$scan_tmp" 2>/dev/null | awk '{print $2}')"
      rm -f "$scan_tmp"
    fi

    recorded_fp=""
    if [[ -f "${HOME}/.ssh/known_hosts" ]]; then
      known_tmp="$(mktemp)"
      if ssh-keygen -F "$remote_host" -f "${HOME}/.ssh/known_hosts" 2>/dev/null | awk '/^[^#]/ {print; exit}' >"$known_tmp"; then
        recorded_fp="$(ssh-keygen -lf "$known_tmp" 2>/dev/null | awk '{print $2}')"
      fi
      rm -f "$known_tmp"
    fi

    if [[ -n "$recorded_fp" && -n "$current_fp" && "$recorded_fp" != "$current_fp" ]]; then
      logger -p auth.warning -t "$LOG_TAG" "managed-domain host key drift detected for ${remote_host}: recorded=${recorded_fp} current=${current_fp}; continuing"
    fi

    ssh_opts+=(
      -o StrictHostKeyChecking=no
      -o UpdateHostKeys=no
    )
  else
    ssh_opts+=(
      -o StrictHostKeyChecking=accept-new
    )
  fi

  if [ -n "$identity_cert_file" ] && [ -s "$identity_cert_file" ]; then
    ssh_opts+=(
      -o CertificateFile="$identity_cert_file"
    )
  fi

  remote_cmd="set -euo pipefail; cd '$remote_repo'; chmod +x modules/nixos/ssh-keys.d/sync-vm-hostkey-keys-yaml.sh modules/nixos/ssh-keys.d/verify-vm-hostkey-from-sops.sh modules/nixos/ssh-keys.d/enroll-vm-hostkey-into-sops.sh; COPILOT_XTRACE=0 modules/nixos/ssh-keys.d/sync-vm-hostkey-keys-yaml.sh --vm '$vm_name' --guest '$guest_name' --profile committed --secrets-file modules/home-manager/ssh.d/keys.yaml"

  if ssh "${ssh_opts[@]}" "${remote_user}@${remote_host}" "$remote_cmd"; then
    env \
      NOW="$(date -Iseconds)" \
      REMOTE_HOST="$remote_host" \
      REMOTE_USER="$remote_user" \
      VM_NAME="$vm_name" \
      GUEST_NAME="$guest_name" \
      yq eval -i '
        .required = false |
        .reason = "synced" |
        .last_sync.status = "success" |
        .last_sync.remote_host = strenv(REMOTE_HOST) |
        .last_sync.remote_user = strenv(REMOTE_USER) |
        .last_sync.vm = strenv(VM_NAME) |
        .last_sync.guest = strenv(GUEST_NAME) |
        .last_sync.updated_at = strenv(NOW) |
        .updated_at = strenv(NOW)
      ' "$STATE_FILE"
    logger -p auth.notice -t "$LOG_TAG" "remote hostkey enrollment sync succeeded via ${remote_user}@${remote_host} vm=${vm_name} guest=${guest_name}"
    exit 0
  fi

  env \
    NOW="$(date -Iseconds)" \
    REMOTE_HOST="$remote_host" \
    REMOTE_USER="$remote_user" \
    VM_NAME="$vm_name" \
    GUEST_NAME="$guest_name" \
    yq eval -i '
      .required = true |
      .last_sync.status = "failed" |
      .last_sync.reason = "remote_sync_failed" |
      .last_sync.remote_host = strenv(REMOTE_HOST) |
      .last_sync.remote_user = strenv(REMOTE_USER) |
      .last_sync.vm = strenv(VM_NAME) |
      .last_sync.guest = strenv(GUEST_NAME) |
      .last_sync.updated_at = strenv(NOW) |
      .updated_at = strenv(NOW)
    ' "$STATE_FILE"
  logger -p auth.err -t "$LOG_TAG" "remote hostkey enrollment sync failed via ${remote_user}@${remote_host} vm=${vm_name} guest=${guest_name}"
  exit 1
}

ndh::logger:command:run "@logTag@" main "$@"
