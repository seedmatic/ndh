#!/usr/bin/env bats
#
# Which keychain roots of an authority the activation removes: every root whose subject
# is exactly CN=<authority> and whose fingerprint is not a trusted slot of keys.yaml —
# a compromised slot, and a retired generation whose slot is gone. Real certificates;
# only the keychain read is replaced by a bundle file.

setup() {
  local rendered="${BATS_TEST_TMPDIR}/post-activation.sh"
  sed -e "s|@nixBashTrampoline@|${NDH_TRAMPOLINE}|g" \
      -e "s|@openssl@|openssl|g" \
      -e "s|@authorities@||g" \
      -e "s|@certPairs@||g" \
      -e '$ { /ndh::logger:command:run/d; }' \
      "${BATS_TEST_DIRNAME}/../post-activation.sh" >"$rendered"
  # shellcheck disable=SC1090
  source "$rendered"

  cert() { # <file> <subject>
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "${BATS_TEST_TMPDIR}/$1.key" -out "${BATS_TEST_TMPDIR}/$1.pem" -subj "$2" -days 1 2>/dev/null
  }
  cert retired "/CN=test-tls"   # a generation whose slot left keys.yaml
  cert current "/CN=test-tls"   # the trusted slot
  cert other "/CN=test-tls-other"
  cert foreign "/CN=test-tls/O=Someone Else"

  bundle="${BATS_TEST_TMPDIR}/keychain.pem"
  cat "${BATS_TEST_TMPDIR}"/{retired,current,other,foreign}.pem >"$bundle"
  keychain::certs() { cat "$bundle"; }
}

fp() { keychain::fingerprint "${BATS_TEST_TMPDIR}/$1.pem"; }

@test "a retired root with the same CN and no slot is removed — the trusted one stays" {
  run keychain::stale test-tls "$(fp current)"
  [ "$status" -eq 0 ]
  [ "$output" = "$(fp retired)" ]
}

@test "with no trusted slot left, every root of the authority is removed" {
  run keychain::stale test-tls ""
  [ "$status" -eq 0 ]
  [ "$(sort <<<"$output")" = "$(printf '%s\n%s\n' "$(fp current)" "$(fp retired)" | sort)" ]
}

@test "a certificate that only CONTAINS the name is never touched" {
  run keychain::stale test-tls "$(fp current)"
  [[ "$output" != *"$(fp other)"* ]]
  [[ "$output" != *"$(fp foreign)"* ]]
}

# The DER of an X.509 Name, base64 — one RDN per <type-oid-hex>=<value> argument, each a
# PrintableString. Built byte by byte: the trust-settings plist stores the issuer this way.
der_name() {
  local rdns="" arg oid value atv
  for arg in "$@"; do
    oid="${arg%%=*}" value="${arg#*=}"
    atv="$(printf '06%02x%s13%02x%s' $((${#oid} / 2)) "$oid" ${#value} "$(printf '%s' "$value" | od -An -tx1 | tr -d ' \n')")"
    atv="$(printf '30%02x%s' $((${#atv} / 2)) "$atv")"
    rdns+="$(printf '31%02x%s' $((${#atv} / 2)) "$atv")"
  done
  printf '30%02x%s' $((${#rdns} / 2)) "$rdns" | xxd -r -p | base64 | tr -d '\n'
}
CN=550403
O=55040a

@test "a stale trust setting of the authority is reported even with no certificate in the keychain" {
  settings="$(printf '%s\t%s\n%s\t%s\n' \
    "$(fp retired)" "$(der_name "$CN=test-tls")" \
    "$(fp current)" "$(der_name "$CN=test-tls")")"
  run keychain::stale_trust test-tls "$(fp current)" "$settings"
  [ "$status" -eq 0 ]
  [ "$output" = "$(fp retired)" ]
}

@test "a trust setting of another name, or of a two-RDN issuer, is never reported" {
  settings="$(printf '%s\t%s\n%s\t%s\n' \
    "$(fp other)" "$(der_name "$CN=test-tls-other")" \
    "$(fp foreign)" "$(der_name "$CN=test-tls" "$O=Someone Else")")"
  run keychain::stale_trust test-tls "$(fp current)" "$settings"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}
