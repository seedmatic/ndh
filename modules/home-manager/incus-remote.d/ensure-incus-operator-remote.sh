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

  # Re-pinning means removing the entry first, and incus refuses to remove the
  # remote that is currently the default — which the last line of this function
  # makes it.  So every run after the first one hit that refusal, the `|| true`
  # that used to guard the removal hid it, `remote add` then failed with
  # "already exists", and the server cert was never pinned.  Nothing reported
  # it: errexit is INERT in here, because the logger calls this function from an
  # `if` condition (shell.d/logger.sh:326), so only checked failures surface —
  # and `main` returned the status of its last command, which succeeded.
  if [[ "$("${incus_bin}" remote get-default 2>/dev/null || true)" == "${remote_name}" ]]; then
    if ! "${incus_bin}" remote set-default local; then
      echo "incus: cannot step off ${remote_name} as the default remote" >&2
      return 1
    fi
  fi
  if "${incus_bin}" remote list --format csv 2>/dev/null | cut -d, -f1 | grep -qxF "${remote_name}"; then
    if ! "${incus_bin}" remote remove "${remote_name}"; then
      echo "incus: cannot remove the stale ${remote_name} remote" >&2
      return 1
    fi
  fi

  # The server's trust store is provisioned by the node itself, so what is
  # normally missing here is only the PINNED SERVER CERT — and pinning needs no
  # token.  Try that first: it keeps the common path free of the token's
  # ten-minute TTL, which made this script depend on a race it did not need.
  # stdin is closed on both attempts because `remote add` prompts when it cannot
  # authenticate, and a prompt in a home activation hangs it.
  #
  # No --project: the rke2lab project is created by the bootstrap (Pulumi's
  # incus:index:Project) and does not exist on a fresh node, so setting it here
  # would fail with "Project not found".
  if ! "${incus_bin}" remote add "${remote_name}" "${remote_address}" \
    --accept-certificate \
    --auth-type tls </dev/null >/dev/null 2>&1; then

    # Client not trusted yet: mint a token.  A node running the daemon locally
    # (the NixOS guest) reaches it over the unix socket; a Mac operator has no
    # local daemon, so mint it on the guest over SSH (CA-authenticated via the
    # ndh SSH config; the guest's incus talks to its own local socket).
    local token=""
    if [[ -S /var/lib/incus/unix.socket ]]; then
      token="$("${incus_bin}" --force-local config trust add "${remote_name}-operator" --quiet 2>/dev/null || true)"
    else
      token="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "${trust_host}" -- \
        incus config trust add "${remote_name}-operator" --quiet 2>/dev/null || true)"
    fi

    # An unreachable server (the guest VM is down at activation time) stays
    # non-fatal by design: warn and leave the remote unconfigured rather than
    # break the whole home activation.  Re-activate once the server is up.
    if [[ -z "${token}" ]]; then
      echo "incus: ${remote_name} is unreachable; leaving it unconfigured (re-activate once the server is up)" >&2
      return 0
    fi

    if ! "${incus_bin}" remote add "${remote_name}" "${remote_address}" \
      --token "${token}" \
      --accept-certificate \
      --auth-type tls </dev/null; then
      echo "incus: could not add ${remote_name} even with a fresh trust token" >&2
      return 1
    fi
  fi

  if ! "${incus_bin}" remote set-default "${remote_name}"; then
    echo "incus: ${remote_name} was added but could not be made the default" >&2
    return 1
  fi

  # Verify rather than assume.  What this script owes its caller is a remote
  # that AUTHENTICATES, not a config entry that looks right — the failure it
  # replaces looked exactly like success.
  if ! "${incus_bin}" info "${remote_name}:" >/dev/null 2>&1; then
    echo "incus: ${remote_name} is configured but still does not authenticate" >&2
    return 1
  fi
}

ndh::logger:command:run "@loggerTag@" main "$@"
