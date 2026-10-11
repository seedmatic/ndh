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
  local certPairs compromisedPairs
  certPairs="@certPairs@"
  compromisedPairs="@compromisedPairs@"

  if [[ -z "$certPairs" && -z "$compromisedPairs" ]]; then
    echo "[tls-authority-keychain] no tls-authority roots to reconcile"
    return 0
  fi

  # Read once: a `security … | grep -q` pipeline under pipefail reports the
  # SIGPIPE grep -q causes, which would read as "absent" for a present root.
  local installed
  installed="$(/usr/bin/security find-certificate -a -Z "$keychain" 2>/dev/null || true)"

  # A compromised root leaves trust FIRST: no longer installing it is not enough, an
  # earlier activation already trusted it, and the leaked private still mints leaves
  # every host would accept. Removed by fingerprint, like it is detected.
  local fp
  while IFS=':' read -r name certFile; do
    [[ -z "$name" ]] && continue
    fp="$(/usr/bin/openssl x509 -noout -fingerprint -sha1 -in "$certFile" | sed -e 's/.*=//' -e 's/://g')"
    grep -qi "SHA-1 hash: ${fp}$" <<<"$installed" || continue
    echo "[tls-authority-keychain] removing compromised $name from System keychain"
    if ! /usr/bin/security delete-certificate -Z "$fp" "$keychain"; then
      echo "[tls-authority-keychain] ERROR: could not remove compromised $name" >&2
      return 1
    fi
  done <<< "$compromisedPairs"

  while IFS=':' read -r name certFile; do
    [[ -z "$name" ]] && continue

    # Presence is decided by FINGERPRINT, never by common name: every generation
    # of an authority carries the same CN, so a CN lookup would take the old root
    # for the new one and never install the second slot of a renewal.
    local fp
    fp="$(/usr/bin/openssl x509 -noout -fingerprint -sha1 -in "$certFile" | sed -e 's/.*=//' -e 's/://g')"
    if grep -qi "SHA-1 hash: ${fp}$" <<<"$installed"; then
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
