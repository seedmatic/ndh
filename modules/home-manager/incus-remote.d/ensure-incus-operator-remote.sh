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

  # Three-valued probe, because what follows is DESTRUCTIVE — it drops the
  # remote — so it may only run on a positive answer that the pin is the
  # problem.  Authenticated: nothing to do, the operator's keypair and pinned
  # cert stay untouched.  Answered with a trust complaint: re-pin.  Anything
  # else (connection refused, timeout, DNS) means "could not look", and a server
  # that is merely down must not cost a pin that is still good.
  local probe_err=""
  if probe_err="$("${incus_bin}" info "${remote_name}:" 2>&1 >/dev/null)"; then
    return 0
  fi
  case "${probe_err}" in
  *x509* | *certificate* | *uthoriz*) ;;
  *)
    echo "incus: ${remote_name} did not answer with a trust error, leaving it untouched: ${probe_err%%$'\n'*}" >&2
    return 0
    ;;
  esac

  # Mint the trust token BEFORE touching the remote: if minting fails we must
  # leave the existing entry alone rather than destroy a pin we cannot replace.
  #
  # The token is not only an authorization secret — it CARRIES the server's
  # certificate fingerprint (verified: the token minted on 2026-09-20 held
  # fa4c5f23…, the same value the node reports as `certificate_fingerprint`), and
  # it travels over SSH, a channel already authenticated by the ndh CA.  So
  # `remote add --token` pins a certificate it can check, where a bare
  # --accept-certificate would trust whatever happens to answer at that address.
  #
  # A node running the daemon locally (the NixOS guest) reaches it over the unix
  # socket; a Mac operator has no local daemon, so mint it on the guest over SSH
  # (the guest's incus talks to its own local socket).
  local token=""
  if [[ -S /var/lib/incus/unix.socket ]]; then
    token="$("${incus_bin}" --force-local config trust add "${remote_name}-operator" --quiet 2>/dev/null || true)"
  else
    token="$(ssh -o ConnectTimeout=8 -o BatchMode=yes "${trust_host}" -- \
      incus config trust add "${remote_name}-operator" --quiet 2>/dev/null || true)"
  fi

  # Non-fatal by design: a server that cannot mint (the guest VM is down at
  # activation time) leaves the remote as it was rather than breaking the whole
  # home activation.  Re-activate once the server is up.
  if [[ -z "${token}" ]]; then
    echo "incus: could not mint a trust token from ${trust_host}; leaving ${remote_name} as it is (re-activate once the server is up)" >&2
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
  if "${incus_bin}" remote list --format json 2>/dev/null \
    | remote="${remote_name}" yq -p json -e 'has(strenv(remote))' >/dev/null 2>&1; then
    if ! "${incus_bin}" remote remove "${remote_name}"; then
      echo "incus: cannot remove the stale ${remote_name} remote" >&2
      return 1
    fi
  fi

  # stdin is closed because `remote add` prompts when it cannot authenticate, and
  # a prompt inside a home activation hangs it.
  #
  # No --project: the rke2lab project is created by the bootstrap (Pulumi's
  # incus:index:Project) and does not exist on a fresh node, so setting it here
  # would fail with "Project not found".
  if ! "${incus_bin}" remote add "${remote_name}" "${remote_address}" \
    --token "${token}" \
    --accept-certificate \
    --auth-type tls </dev/null; then
    echo "incus: could not add ${remote_name} with a fresh trust token" >&2
    return 1
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
