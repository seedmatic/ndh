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
