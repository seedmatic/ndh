#!/usr/bin/env -S bash -euo pipefail
# @codebase
# ndh-keychain-reconcile — the darwin System keychain holds EXACTLY each tls-authority's
# trusted roots. The activation runs it; the operator re-runs it (`sudo
# ndh-keychain-reconcile`) from a Terminal in the GUI session when an activation over ssh
# could not apply a trust setting; `--check` reports without changing anything.
#
# For every keys.yaml authority that advertises `tls-authority` usage:
#   1. every trusted slot (not compromised) is installed AND verified trusted by SecTrust;
#   2. every STALE root is removed with its trust setting — UNCONDITIONALLY. A stale root is
#      never legitimate: it is a compromised slot, or a retired one, and a retirement only
#      happens after the phase-2 gate proved its successor trusted everywhere. Keeping it
#      protects no availability and preserves the exposure;
#   3. the ADMIN TRUST SETTINGS are re-read: a trust setting applies to a certificate by
#      digest even once the certificate has left the keychain, so a server presenting that
#      root is still trusted. Any entry for this authority that is not a trusted slot is
#      "STALE root STILL TRUSTED".
#
# Setting or removing a trust setting needs an admin authorization only an interactive GUI
# session provides (no authorizationdb lift, operator decision 2026-10-11). Over ssh,
# `add-trusted-cert` imports WITHOUT trusting and `-t` removal is denied; both are errors
# that name the gesture, and the run exits 1.
#
# Background: nix-darwin's `security.pki.certificates` writes the bundle at
# /etc/ssl/certs/ca-certificates.crt — honoured by every SSL_CERT_FILE reader — but Apple's
# SecTrust does NOT consult it: the Tailscale native daemon, notarised apps, Safari need the
# root in /Library/Keychains/System.keychain.
#
# Every generation of an authority carries the same subject, so roots are told apart by
# FINGERPRINT; an ndh root is recognised by its subject (and, for a self-signed root, its
# issuer) being exactly `CN=<authority>`, the shape authority-bootstrap-tls-root mints, so a
# foreign certificate that merely contains the name is never touched.
#
# Apple's SecTrust accepts ECDSA P-256 roots cleanly; an Ed25519 root is refused at import —
# warned, and left to the bundle.

source @nixBashTrampoline@

keychain="/Library/Keychains/System.keychain"
gesture="run \`sudo ndh-keychain-reconcile\` from a Terminal in the GUI session"

keychain::fingerprint() { # <pem file>
  @openssl@ x509 -noout -fingerprint -sha1 -in "$1" | sed -e 's/.*=//' -e 's/://g'
}

# The PEM bundle of the keychain's certificates whose subject CONTAINS <authority>
# (`security -c` is a substring match; keychain::stale narrows it).
keychain::certs() { # <authority>
  /usr/bin/security find-certificate -a -c "$1" -p "$keychain" 2>/dev/null || true
}

# The admin-domain trust settings, one "<SHA-1><TAB><issuer DER, base64>" per line. Fails (2)
# when they cannot be read: an unreadable store is not an empty one.
keychain::trust_settings() {
  local plist fp
  plist="$(mktemp)"
  /usr/bin/security trust-settings-export -d "$plist" >/dev/null 2>&1 || {
    rm -f "$plist"
    return 2
  }
  while IFS= read -r fp; do
    printf '%s\t%s\n' "$fp" \
      "$(/usr/bin/plutil -extract "trustList.${fp}.issuerName" raw -o - "$plist" 2>/dev/null || true)"
  done < <(/usr/bin/plutil -p "$plist" | grep -oE '"[0-9A-F]{40}" =>' | tr -d '" =>')
  rm -f "$plist"
}

# Whether SecTrust trusts <pem> as an anchor — present in the keychain is not enough.
keychain::trusted() { # <pem file>
  /usr/bin/security verify-cert -c "$1" -k "$keychain" >/dev/null 2>&1
}

# The keychain roots to remove for <authority>: subject exactly CN=<authority>, fingerprint
# not among <trusted> (one per line).
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

# The admin trust settings still in force for <authority> that are not a trusted slot: the
# issuer is exactly CN=<authority> (one RDN, commonName) and the fingerprint is not trusted.
# <settings> is keychain::trust_settings' output.
keychain::stale_trust() { # <authority> <trusted fingerprints> <settings>
  local name="$1" trusted="$2" settings="$3" fp issuer prims
  while IFS=$'\t' read -r fp issuer; do
    [[ -n "$fp" && -n "$issuer" ]] || continue
    prims="$(base64 -d <<<"$issuer" 2>/dev/null | @openssl@ asn1parse -inform DER 2>/dev/null | grep 'prim:' || true)"
    [[ "$(grep -c 'prim:' <<<"$prims")" == 2 ]] || continue
    grep -q 'OBJECT *:commonName$' <<<"$prims" || continue
    grep -qE "STRING *:${name}\$" <<<"$prims" || continue
    grep -qix -- "$fp" <<<"$trusted" || printf '%s\n' "$fp"
  done <<<"$settings"
}

# Install <pem> as a trusted root. 0 on success; 2 when the trust setting needs an
# authorization this session lacks (the root is then present but NOT trusted); 1 for a
# format refusal (an Ed25519 root SecTrust cannot import).
keychain::install() { # <id> <pem file>
  local err
  if err="$(/usr/bin/security add-trusted-cert -d -r trustRoot -k "$keychain" "$2" 2>&1)"; then
    return 0
  fi
  if grep -qiE 'authorization|user interaction' <<<"$err"; then
    return 2
  fi
  echo "[ndh-keychain-reconcile] WARN: SecTrust refused $1 (${err}); leaving it to the bundle" >&2
  return 1
}

main() {
  local check=0
  [[ "${1:-}" == "--check" ]] && check=1

  # authorities: the tls-authority names; certPairs: "<authority>@<slot>:<pem path>" per
  # TRUSTED slot, newline-separated.
  local authorities certPairs
  authorities="@authorities@"
  certPairs="@certPairs@"

  if [[ -z "$authorities" ]]; then
    echo "[ndh-keychain-reconcile] no tls-authority roots to reconcile"
    return 0
  fi

  local installed
  # Read once: a `security … | grep -q` pipeline under pipefail reports the SIGPIPE grep -q
  # causes, which would read as "absent" for a present root.
  installed="$(/usr/bin/security find-certificate -a -Z "$keychain" 2>/dev/null || true)"

  local name pair id certFile trusted fp rc settings unavailable=0 exposed=0 unreadable=0
  for name in $authorities; do
    trusted=""

    # 1. install and verify every trusted slot
    while IFS= read -r pair; do
      [[ -n "$pair" ]] || continue
      id="${pair%%:*}"
      certFile="${pair#*:}"
      [[ "${id%@*}" == "$name" ]] || continue
      fp="$(keychain::fingerprint "$certFile")"
      trusted+="${fp}"$'\n'
      if ((check == 0)) && ! grep -qi "SHA-1 hash: ${fp}$" <<<"$installed"; then
        echo "[ndh-keychain-reconcile] installing $id to System keychain"
        rc=0
        keychain::install "$id" "$certFile" || rc=$?
        ((rc == 1)) && continue # a format refusal: never reaches SecTrust
      fi
      if ! keychain::trusted "$certFile"; then
        echo "[ndh-keychain-reconcile] ERROR: ${name}: trusted root ${id} NOT installed/trusted — ${gesture}" >&2
        unavailable=$((unavailable + 1))
      fi
    done <<<"$certPairs"

    if [[ -z "$trusted" ]]; then
      echo "[ndh-keychain-reconcile] ${name}: keys.yaml has no trusted slot — ALL its roots are stale" >&2
    fi

    # 2. remove every stale root with its trust setting, whatever step 1 found
    if ((check == 0)); then
      while IFS= read -r fp; do
        [[ -n "$fp" ]] || continue
        echo "[ndh-keychain-reconcile] removing ${name} root ${fp} and its trust setting — not a trusted slot of keys.yaml"
        /usr/bin/security delete-certificate -Z "$fp" -t "$keychain" >/dev/null 2>&1 || true
      done < <(keychain::stale "$name" "$trusted")
    fi

    # 3. what is still in force: a stale cert still in the keychain, or a stale trust setting
    settings="$(keychain::trust_settings)" || {
      unreadable=1
      settings=""
    }
    while IFS= read -r fp; do
      [[ -n "$fp" ]] || continue
      echo "[ndh-keychain-reconcile] ERROR: ${name}: STALE root ${fp} still in the System keychain — removal denied; ${gesture}" >&2
      exposed=$((exposed + 1))
    done < <(keychain::stale "$name" "$trusted")
    while IFS= read -r fp; do
      [[ -n "$fp" ]] || continue
      echo "[ndh-keychain-reconcile] ERROR: ${name}: STALE root ${fp} STILL TRUSTED (admin trust setting) — removal denied; ${gesture}" >&2
      exposed=$((exposed + 1))
    done < <(keychain::stale_trust "$name" "$trusted" "$settings")
  done

  # Exit contract shared with ndh-trust-check: 0 clean, 1 a stale root still trusted or a
  # trusted root not trusted, 2 the trust settings could not be read.
  if ((exposed > 0 || unavailable > 0)); then
    echo "[ndh-keychain-reconcile] NOT reconciled: ${exposed} stale root(s) still trusted, ${unavailable} trusted root(s) not trusted" >&2
    return 1
  fi
  if ((unreadable > 0)); then
    echo "[ndh-keychain-reconcile] the admin trust settings could not be read — run with sudo for a verdict" >&2
    return 2
  fi
  echo "[ndh-keychain-reconcile] reconciled: every tls-authority holds exactly its trusted roots"
}

ndh::logger:command:run ndh-keychain-reconcile main "$@"
