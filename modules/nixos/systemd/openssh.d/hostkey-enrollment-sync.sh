#!/usr/bin/env bash
# @codebase
set -euo pipefail

# shellcheck disable=SC1091
source @nixBashTrampoline@

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

  is_managed_domain_host=0

  resolve_remote_host() {
    local base_host="$1"
    local domain_hint="${NDH_DOMAIN:-}"
    local cand=""
    local -a candidates=()

    # Already an FQDN (or explicit dotted host): keep as-is.
    if [[ "$base_host" == *.* ]]; then
      printf '%s\n' "$base_host"
      return 0
    fi

    if [[ -n "${NDH_RDP_HOST_FQDN:-}" ]]; then
      candidates+=("${NDH_RDP_HOST_FQDN}")
    fi

    # Catalog/profile domain hint (e.g. tailnet.local) if provided.
    if [[ -n "$domain_hint" ]]; then
      domain_hint="${domain_hint#.}"
      candidates+=("${base_host}.${domain_hint}")
    fi

    # Canonical local LAN/mDNS candidates used in this codebase.
    candidates+=(
      "${base_host}.local"
      "${base_host}.lan"
    )

    for cand in "${candidates[@]}"; do
      if command -v getent >/dev/null 2>&1; then
        if getent ahostsv4 "$cand" >/dev/null 2>&1 || getent hosts "$cand" >/dev/null 2>&1; then
          printf '%s\n' "$cand"
          return 0
        fi
      fi

      # Fallback resolver probe when getent is unavailable/non-functional.
      if ssh-keyscan -T 3 -t ed25519 "$cand" >/dev/null 2>&1; then
        printf '%s\n' "$cand"
        return 0
      fi
    done

    # Final fallback: preserve caller-provided value.
    printf '%s\n' "$base_host"
    return 0
  }

  remote_host="$(resolve_remote_host "$remote_host")"

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

  ssh_max_attempts="${NDH_ENROLL_SSH_RETRY_MAX_ATTEMPTS:-6}"
  ssh_retry_delay_seconds="${NDH_ENROLL_SSH_RETRY_DELAY_SECONDS:-3}"
  ssh_attempt=1
  ssh_last_rc=1
  ssh_last_error=""

  while [ "$ssh_attempt" -le "$ssh_max_attempts" ]; do
    ssh_err_file="$(mktemp)"
    if ssh "${ssh_opts[@]}" "${remote_user}@${remote_host}" "$remote_cmd" 2>"$ssh_err_file"; then
      rm -f "$ssh_err_file"
      ssh_last_rc=0
      break
    fi

    ssh_last_rc=$?
    ssh_last_error="$(cat "$ssh_err_file")"
    rm -f "$ssh_err_file"

    if [ "$ssh_attempt" -lt "$ssh_max_attempts" ]
    then
      if printf '%s' "$ssh_last_error" | grep -Eqi 'Could not resolve hostname|Temporary failure in name resolution|Name or service not known|Device or resource busy'; then
        logger -p auth.warning -t "$LOG_TAG" "remote host lookup/connect transient failure (attempt ${ssh_attempt}/${ssh_max_attempts}) for ${remote_host}; retrying in ${ssh_retry_delay_seconds}s"
        sleep "$ssh_retry_delay_seconds"
        ssh_attempt=$((ssh_attempt + 1))
        continue
      fi
    fi

    break
  done

  if [ "$ssh_last_rc" -eq 0 ]; then
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

  if [ -n "$ssh_last_error" ]; then
    logger -p auth.err -t "$LOG_TAG" "remote hostkey enrollment sync ssh error: ${ssh_last_error}"
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
