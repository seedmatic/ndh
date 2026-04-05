#!/usr/bin/env -S bash -euo pipefail
source @logger@

main() {
  remote_host="@remoteHost@"
  local_client_cert="@localClientCert@"
  trust_entry_name="@trustEntryName@"

  if [[ ! -f "${local_client_cert}" ]]; then
    echo "[incus-remote-trust] local client cert missing: ${local_client_cert}; skipping"
    return 0
  fi

  if ! command -v ssh >/dev/null 2>&1; then
    echo "[incus-remote-trust] ssh command not available; skipping"
    return 0
  fi

  if ! command -v openssl >/dev/null 2>&1; then
    echo "[incus-remote-trust] openssl command not available; skipping"
    return 0
  fi

  if ! ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_host}" true >/dev/null 2>&1; then
    echo "[incus-remote-trust] cannot reach ${remote_host} via ssh; skipping"
    return 0
  fi

  local_fingerprint="$(openssl x509 -in "${local_client_cert}" -noout -fingerprint -sha256 | sed 's/^.*=//' | tr -d ':' | tr 'A-F' 'a-f')"
  if [[ -z "${local_fingerprint}" ]]; then
    echo "[incus-remote-trust] unable to compute local certificate fingerprint; skipping"
    return 0
  fi

  short_fingerprint="${local_fingerprint:0:12}"

  if ssh "${remote_host}" "incus config trust list --format csv | awk -F, '{print \$4}' | grep -Fxq '${short_fingerprint}'"; then
    echo "[incus-remote-trust] certificate already trusted on ${remote_host} (${short_fingerprint})"
    return 0
  fi

  remote_cert="/tmp/incus-client-$(date +%s)-$$.crt"
  ssh "${remote_host}" "cat > '${remote_cert}'" < "${local_client_cert}"

  if ssh "${remote_host}" "incus --force-local config trust add-certificate '${remote_cert}' --name '${trust_entry_name}'"; then
    echo "[incus-remote-trust] trusted local cert on ${remote_host} as ${trust_entry_name}"
  else
    echo "[incus-remote-trust] trust add returned non-zero on ${remote_host}; continuing"
  fi

  ssh "${remote_host}" "rm -f '${remote_cert}'" >/dev/null 2>&1 || true
}

ndh::logger:command:run darwin.activationScripts.postActivation.incus-remote-trust main "$@"