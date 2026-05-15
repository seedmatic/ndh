#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Darwin post-activation hook for TLS authority keychain reconciliation.
#
# Installs every keys.yaml authority that advertises `tls-authority` usage
# into /Library/Keychains/System.keychain so Apple's SecTrust accepts certs
# they sign.
#
# Background: nix-darwin's `security.pki.certificates` writes the bundle at
# /etc/ssl/certs/ca-certificates.crt — which Go's pure-Go verifier honours
# via SSL_CERT_FILE, but Apple's SecTrust does NOT consult.  Anything that
# goes through Apple's frameworks (Tailscale's native daemon, every HTTPS
# call from a notarised Mac app, Safari, Chrome) needs the root in
# /Library/Keychains/System.keychain.
#
# `security add-trusted-cert -d -r trustRoot` achieves that with explicit
# "always trust" semantics scoped to the whole machine.  Idempotent —
# re-running on an already-trusted cert is a no-op.
#
# Apple's SecTrust accepts ECDSA P-256 roots cleanly.  Ed25519 roots are
# rejected with "Unknown format in import" — this script gracefully warns
# and continues (those roots remain in the bundle for Go-verifier consumers).

source @nixBashTrampoline@

main() {
  local keychain="/Library/Keychains/System.keychain"
  local needs_update=false
  local cert_count=@certCount@

  # certPairs is a newline-separated list of "name:path" pairs
  local certPairs
  certPairs="@certPairs@"

  if [[ -z "$certPairs" ]]; then
    echo "[tls-authority-keychain] no tls-authority roots to reconcile"
    return 0
  fi

  while IFS=':' read -r name certFile; do
    [[ -z "$name" ]] && continue

    # Check if already installed by matching on the authority name
    # (which should match the cert's CN in our keys.yaml schema)
    if /usr/bin/security find-certificate -c "$name" "$keychain" >/dev/null 2>&1; then
      # Silent on already-installed certs to reduce noise on repeated activations
      continue
    fi

    needs_update=true
    echo "[tls-authority-keychain] installing $name to System keychain"

    # Attempt to add the certificate
    if ! /usr/bin/security add-trusted-cert -d -r trustRoot -k "$keychain" "$certFile" 2>/dev/null; then
      echo "[tls-authority-keychain] WARN: SecTrust refused $name (likely Ed25519); leaving SSL_CERT_FILE-only" >&2
    fi
  done <<< "$certPairs"

  if [[ "$needs_update" == "false" ]]; then
    # Silent when all certs are already installed
    :
  fi
}

ndh::logger:command:run darwin.activationScripts.postActivation.tls-authority-keychain main "$@"
