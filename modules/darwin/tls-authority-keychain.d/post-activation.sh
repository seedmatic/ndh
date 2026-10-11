#!/usr/bin/env -S bash -euo pipefail
# @codebase
# Darwin post-activation hook for TLS authority keychain reconciliation.
#
# For every keys.yaml authority that advertises `tls-authority` usage, the System
# keychain holds EXACTLY its trusted roots: every slot that is not compromised is
# installed, and every other root that authority ever had is removed — a compromised
# slot, but also a retired generation whose slot is gone from keys.yaml. A root that
# stays in the keychain stays trusted by SecTrust (empty trust settings read as
# "always trust"), and whoever holds its private still mints accepted leaves.
#
# Background: nix-darwin's `security.pki.certificates` writes the bundle at
# /etc/ssl/certs/ca-certificates.crt — which Go's pure-Go verifier honours
# via SSL_CERT_FILE, but Apple's SecTrust does NOT consult.  Anything that
# goes through Apple's frameworks (Tailscale's native daemon, every HTTPS
# call from a notarised Mac app, Safari, Chrome) needs the root in
# /Library/Keychains/System.keychain.
#
# Every generation of an authority carries the same subject, so roots are told apart
# by FINGERPRINT; an ndh root is recognised by its subject being exactly
# `CN=<authority>`, the shape authority-bootstrap-tls-root mints, so a foreign
# certificate that merely contains the name is never touched.
#
# Apple's SecTrust accepts ECDSA P-256 roots cleanly.  Ed25519 roots are
# rejected with "Unknown format in import" — this script warns and continues
# (those roots remain in the bundle for Go-verifier consumers).

source @nixBashTrampoline@

keychain="/Library/Keychains/System.keychain"

keychain::fingerprint() { # <pem file>
  @openssl@ x509 -noout -fingerprint -sha1 -in "$1" | sed -e 's/.*=//' -e 's/://g'
}

# The PEM bundle of the keychain's certificates whose subject CONTAINS <authority>
# (`security -c` is a substring match; keychain::stale narrows it).
keychain::certs() { # <authority>
  /usr/bin/security find-certificate -a -c "$1" -p "$keychain" 2>/dev/null || true
}

# The fingerprints to remove for <authority>: every keychain root whose subject is
# exactly CN=<authority> and whose fingerprint is not among <trusted> (one per line).
keychain::stale() { # <authority> <trusted fingerprints>
  local name="$1" trusted="$2" dir file fp subject
  dir="$(mktemp -d)"
  keychain::certs "$name" | awk -v d="$dir" '
    /-----BEGIN CERTIFICATE-----/ { n++; f = d "/" n ".pem" }
    f { print > f }
    /-----END CERTIFICATE-----/ { close(f); f = "" }'
  for file in "$dir"/*.pem; do
    [[ -e "$file" ]] || continue
    subject="$(@openssl@ x509 -noout -subject -nameopt RFC2253 -in "$file" | sed -e 's/^subject=//')"
    [[ "$subject" == "CN=${name}" ]] || continue
    fp="$(keychain::fingerprint "$file")"
    grep -qix -- "$fp" <<<"$trusted" || printf '%s\n' "$fp"
  done
  rm -rf "$dir"
}

main() {
  # authorities: the tls-authority names; certPairs: "<authority>@<slot>:<pem path>"
  # per TRUSTED slot, newline-separated.
  local authorities certPairs
  authorities="@authorities@"
  certPairs="@certPairs@"

  if [[ -z "$authorities" ]]; then
    echo "[tls-authority-keychain] no tls-authority roots to reconcile"
    return 0
  fi

  local name pair id certFile trusted stale fp
  for name in $authorities; do
    trusted=""
    while IFS= read -r pair; do
      [[ -n "$pair" ]] || continue
      id="${pair%%:*}"
      certFile="${pair#*:}"
      [[ "${id%@*}" == "$name" ]] || continue
      trusted+="$(keychain::fingerprint "$certFile")"$'\n'
    done <<<"$certPairs"

    stale="$(keychain::stale "$name" "$trusted")" || return 1
    while IFS= read -r fp; do
      [[ -n "$fp" ]] || continue
      echo "[tls-authority-keychain] removing ${name} root ${fp} — not a trusted slot of keys.yaml"
      if ! /usr/bin/security delete-certificate -Z "$fp" "$keychain"; then
        echo "[tls-authority-keychain] ERROR: could not remove ${name} root ${fp}" >&2
        return 1
      fi
    done <<<"$stale"
  done

  # Read once: a `security … | grep -q` pipeline under pipefail reports the
  # SIGPIPE grep -q causes, which would read as "absent" for a present root.
  local installed
  installed="$(/usr/bin/security find-certificate -a -Z "$keychain" 2>/dev/null || true)"

  while IFS=':' read -r id certFile; do
    [[ -n "$id" ]] || continue
    fp="$(keychain::fingerprint "$certFile")"
    grep -qi "SHA-1 hash: ${fp}$" <<<"$installed" && continue
    echo "[tls-authority-keychain] installing $id to System keychain"
    if ! /usr/bin/security add-trusted-cert -d -r trustRoot -k "$keychain" "$certFile" 2>/dev/null; then
      echo "[tls-authority-keychain] WARN: SecTrust refused $id (likely Ed25519); leaving SSL_CERT_FILE-only" >&2
    fi
  done <<<"$certPairs"
}

ndh::logger:command:run darwin.activationScripts.postActivation.tls-authority-keychain main "$@"
