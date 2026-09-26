#!/usr/bin/env -S bash -euo pipefail
source @nixBashTrampoline@

# Fingerprint of a PEM certificate, in the short form incus itself prints in `config trust list`.
cert_fingerprint() {
  openssl x509 -noout -fingerprint -sha256 "$@" 2>/dev/null |
    sed 's/^.*=//' | tr -d ':' | tr 'A-F' 'a-f'
}

# The OTHER half of "remote trust", and it was missing: the client pins the SERVER's certificate, and
# a Tart factory reset recreates the guest's /var/lib/incus — so the daemon comes back with a new
# certificate while the client still pins the old one, and every command fails with "certificate
# signed by unknown authority".  Measured 2026-09-26: pinned a430e76cad9d against a live
# 5e1047c1ff38.  Reconciled here rather than repaired by hand, because the failure arrives once per
# renew and its cause is invisible from the error message.
#
# Fetched over SSH on purpose: that is an authenticated channel, unlike trust-on-first-use against
# the very endpoint whose identity is in question.  A real fix would have the daemon serve a
# certificate issued by the fleet's own `mammoth-skate-tls` authority, so nothing is pinned and the
# identity survives a renew — that is not done, and this reconciliation is the honest stand-in.
#
# ★ WHICH file the daemon serves depends on its mode, so it is not assumed.  Measured 2026-09-26: a
# standalone daemon serves /var/lib/incus/server.crt (the one ensure-incus-server-cert provisions,
# with the full SAN list), but once the member joins a cluster it serves the self-generated
# /var/lib/incus/cluster.crt — a different key, with a single `DNS:<member>` SAN.  Pinning server.crt
# on a clustered member pins a certificate that is never presented, and the client then fails with a
# message that names the right host, which reads like a name problem and is not one.
#
# So the WIRE selects and SSH supplies: the handshake says which certificate is live, and the bytes
# we pin are always the ones fetched over ssh.  Never trust-on-first-use — a certificate read only
# from the endpoint whose identity is in question proves nothing.  (openssl is deliberately not
# required ON the host: it is absent there, measured, and adding it to a NixOS host's closure to run
# a diagnostic would be the wrong trade.)
reconcile_pinned_server_cert() {
  local pin="$1"
  [[ -n "${pin}" ]] || return 0

  local wire_fp
  wire_fp="$(openssl s_client -connect "${remote_host}:8443" </dev/null 2>/dev/null |
    openssl x509 2>/dev/null | cert_fingerprint)"
  if [[ -z "${wire_fp}" ]]; then
    echo "[incus-remote-trust] ${remote_host}:8443 presented no certificate; leaving the pin as it is"
    return 0
  fi

  local pinned_fp=""
  [[ -f "${pin}" ]] && pinned_fp="$(cert_fingerprint -in "${pin}")"
  if [[ "${wire_fp}" == "${pinned_fp}" ]]; then
    echo "[incus-remote-trust] pinned server certificate is current (${wire_fp:0:12})"
    return 0
  fi

  local candidate cert
  for candidate in cluster.crt server.crt; do
    cert="$(ssh -o BatchMode=yes -o ConnectTimeout=5 "${remote_host}" \
      "cat /var/lib/incus/${candidate}" 2>/dev/null || true)"
    [[ -n "${cert}" ]] || continue
    [[ "$(printf '%s\n' "${cert}" | cert_fingerprint)" == "${wire_fp}" ]] || continue

    # No backup kept: the authoritative copy lives on the host and can be re-fetched at any time, so
    # a stale copy beside it would only be one more thing that can be wrong.
    mkdir -p "$(dirname "${pin}")"
    printf '%s\n' "${cert}" >"${pin}"
    echo "[incus-remote-trust] refreshed the pin from ${candidate}: ${pinned_fp:0:12}${pinned_fp:+ -> }${wire_fp:0:12}"
    return 0
  done

  echo "[incus-remote-trust] the certificate served by ${remote_host} (${wire_fp:0:12}) matches no file we can read over ssh; leaving the pin as it is" >&2
}

main() {
  remote_host="@remoteHost@"
  local_client_cert="@localClientCert@"
  trust_entry_name="@trustEntryName@"
  server_cert_pin="@serverCertPin@"

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

  # Both directions are reconciled, and the server half FIRST: it is the one that breaks every
  # client command, and it does not depend on the local client certificate existing.
  reconcile_pinned_server_cert "${server_cert_pin}"

  if [[ ! -f "${local_client_cert}" ]]; then
    echo "[incus-remote-trust] local client cert missing: ${local_client_cert}; skipping the client half"
    return 0
  fi

  local_fingerprint="$(cert_fingerprint -in "${local_client_cert}")"
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