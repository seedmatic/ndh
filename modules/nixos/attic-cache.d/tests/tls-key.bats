#!/usr/bin/env bats
#
# attic-tls-key: the cache container's TLS key is generated ONCE and never replaced, so a leaf the
# operator seat signed on its CSR keeps certifying the key nginx serves; a leaf that certifies
# another key is refused. Only chgrp is stubbed (the test runs as a user without the nginx group).

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/tls"
  printf '#!/usr/bin/env bash\nexit 0\n' >"$t/bin/chgrp"
  chmod +x "$t/bin/chgrp"
  script="${BATS_TEST_DIRNAME}/../tls-key.sh"
}

run_key() { PATH="$t/bin:$PATH" run bash -euo pipefail "$script" "$t/tls" attic.m1 nginx; }
pub() { openssl pkey -in "$t/tls/key.pem" -pubout; }

@test "the first start generates an ECDSA P-256 key, 0640, and a CSR naming the cache alone" {
  run_key
  [ "$status" -eq 0 ]
  [[ "$(openssl pkey -in "$t/tls/key.pem" -noout -text | grep -E 'ASN1 OID|NIST')" == *"prime256v1"* ]]
  [ "$(stat -c %a "$t/tls/key.pem" 2>/dev/null || stat -f %Lp "$t/tls/key.pem")" = 640 ]
  [[ "$(openssl req -in "$t/tls/request.csr" -noout -text | grep -A1 'Subject Alternative Name' | tail -1 | tr -d ' ')" == "DNS:attic.m1" ]]
}

@test "a restart never replaces the key: its public is the same, the CSR is rewritten on it" {
  run_key
  before="$(pub)"
  rm "$t/tls/request.csr"
  run_key
  [ "$status" -eq 0 ]
  [ "$(pub)" = "$before" ]
  [ "$(openssl req -in "$t/tls/request.csr" -noout -pubkey)" = "$before" ]
}

@test "a leaf that certifies another key is refused" {
  run_key
  openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes -keyout "$t/other.key" \
    -out "$t/tls/cert.pem" -subj "/CN=attic.m1" -days 1 2>/dev/null
  run_key
  [ "$status" -eq 1 ]
  [[ $output == *"does not certify"* ]]
}

@test "a leaf on the held key is accepted" {
  run_key
  openssl x509 -req -in "$t/tls/request.csr" -signkey "$t/tls/key.pem" -out "$t/tls/cert.pem" -days 1 2>/dev/null
  run_key
  [ "$status" -eq 0 ]
}
