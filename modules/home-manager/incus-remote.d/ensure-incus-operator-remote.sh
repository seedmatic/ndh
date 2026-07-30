#!/usr/bin/env -S bash -euo pipefail
# Provision the operator's ~/.config/incus remote (client identity + trust).
# Idempotent: a no-op once the remote authenticates. NDH_BOOTSTRAP_* mirror the
# sibling activation scripts (skip the bootstrap runtime presence check).
export NDH_BOOTSTRAP_INSTALLER_MODE=1
export NDH_BOOTSTRAP_STRICT=0
# shellcheck disable=SC1091
source @nixBashTrampoline@

incus_bin="@incus@"
remote_name="@remoteName@"
remote_address="@remoteAddress@"
trust_host="@trustHost@"

config_dir="${XDG_CONFIG_HOME:-${HOME}/.config}/incus"

main() {
  install -d -m 0700 "${config_dir}"

  # Reconcile the remote's URL to the current address (cheap, no re-trust): heals
  # an entry that drifted to a slow .local address. A no-op — and harmlessly
  # ignored — when the remote does not exist yet.
  "${incus_bin}" remote set-url "${remote_name}" "${remote_address}" >/dev/null 2>&1 || true

  # Already authenticated → nothing to do (keeps the operator's existing keypair
  # and pinned server cert untouched on every activation).
  if "${incus_bin}" info "${remote_name}:" >/dev/null 2>&1; then
    return 0
  fi

  # Mint a trust token from the Incus server. A node that runs the daemon locally
  # (the NixOS guest) reaches it over the unix socket; a Mac operator has no local
  # daemon, so mint it on the guest over SSH (CA-authenticated via the ndh SSH
  # config; the guest's incus talks to its own local socket).
  #
  # Non-fatal by design: if the server is unreachable (e.g. the guest VM is down
  # at activation time), warn and leave the remote unconfigured rather than break
  # the whole home activation. Re-activate once the server is up.
  local token=""
  if [[ -S /var/lib/incus/unix.socket ]]; then
    token="$("${incus_bin}" --force-local config trust add "${remote_name}-operator" --quiet 2>/dev/null || true)"
  else
    token="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "${trust_host}" -- \
      incus config trust add "${remote_name}-operator" --quiet 2>/dev/null || true)"
  fi

  if [[ -z "${token}" ]]; then
    echo "incus: could not mint a trust token from ${trust_host}; leaving ${remote_name} unconfigured (re-activate once the server is reachable)" >&2
    return 0
  fi

  # `remote add` with the token: pins the server cert (--accept-certificate),
  # generates the operator client keypair (nxmatic@<host>) if absent, and sets
  # auth_type=tls. No --project: the rke2lab project is created by the bootstrap
  # (Pulumi's incus:index:Project) and does not exist on a fresh node, so setting
  # it here would fail with "Project not found". Drop any stale half-added remote
  # first (e.g. a prior attempt that pinned the cert but never authenticated).
  "${incus_bin}" remote remove "${remote_name}" >/dev/null 2>&1 || true
  "${incus_bin}" remote add "${remote_name}" "${remote_address}" \
    --token "${token}" \
    --accept-certificate \
    --auth-type tls
  "${incus_bin}" remote set-default "${remote_name}"
}

ndh::logger:command:run "@loggerTag@" main "$@"
