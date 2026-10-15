#!/usr/bin/env bats
#
# incus-cluster-cert-renew on its REAL path: classification, preflight, the exit contract, and the
# renewal itself — a CSR made on the member's EXISTING cluster key, signed on the seat, installed.
#
# Only the outside world is stubbed, first on PATH: sops (a test keys.yaml with a real CA),
# `openssl s_client` (the leaf "served", first from an OLD test CA, so the cluster needs RENEW; it
# verifies for real against the -CAfile it is given; every other openssl subcommand runs the real
# one), ssh (a member simulated locally: its command runs here, its cluster key is a test key, its
# sudo is a no-op), incus (update-certificate makes the new leaf the served one) and systemctl.

bats_require_minimum_version 1.5.0

setup() {
  realOpenssl="$(command -v openssl)"
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/home"

  ca() { # <name> — a self-signed P-256 test root
    "$realOpenssl" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$t/$1.key" -out "$t/$1.crt" -subj "/CN=test-tls" -days 3650 \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  }
  ca current
  ca old
  "$realOpenssl" req -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
    -keyout "$t/leaf.key" -out "$t/leaf.csr" -subj "/CN=m1" 2>/dev/null
  "$realOpenssl" x509 -req -in "$t/leaf.csr" -CA "$t/old.crt" -CAkey "$t/old.key" \
    -CAcreateserial -out "$t/served.crt" -days 30 2>/dev/null

  CA="$(<"$t/current.crt")" KEY="$(<"$t/current.key")" yq --null-input '
    {"authorities": {"test-tls": {"usage": ["tls-authority"],
      "slots": {"26-10-10": {"ca_crt": strenv(CA), "private": strenv(KEY)}}}}}' >"$t/keys.yaml"

  cat >"$t/bin/sops" <<EOF
#!/usr/bin/env bash
cat "$t/keys.yaml"
EOF
  cat >"$t/bin/openssl" <<EOF
#!/usr/bin/env bash
if [[ \$1 == s_client ]]; then
  [[ -n \${STUB_ABSENT:-} ]] && exit 1
  echo CONNECTED
  cat "$t/served.crt"
  ca=""
  while ((\$#)); do [[ \$1 == -CAfile ]] && ca=\$2; shift; done
  if [[ -n \$ca ]] && "$realOpenssl" verify -CAfile "\$ca" "$t/served.crt" >/dev/null 2>&1; then
    echo "Verification: OK"
  else
    echo "Verification error: unable to verify the first certificate"
  fi
  exit 0
fi
exec "$realOpenssl" "\$@"
EOF
  mkdir -p "$t/run"
  cat >"$t/bin/ssh" <<EOF
#!/usr/bin/env bash
cmd="\${!#}"
if [[ \$cmd == *'rsudo="\$1"'* ]]; then
  if [[ -n \${STUB_SSH_ERROR:-} ]]; then
    echo "ERROR /run/wrappers/bin/sudo is not the setuid sudo: must be owned by uid 0"
  else
    echo "OK /run/wrappers/bin/sudo runs without a password"
  fi
  echo "OK incus on PATH"
  echo "OK step on PATH"
  echo "OK /var/lib/incus/cluster.key present"
  echo "OK /run/user/501 present (tmpfs)"
  exit 0
fi
# The member, simulated here: its sudo is a no-op, its cluster key a test key, its tmpfs a test dir.
cmd="\${cmd//\/run\/wrappers\/bin\/sudo/}"
cmd="\${cmd//\/var\/lib\/incus\/cluster.key/\${STUB_CLUSTER_KEY:-$t/leaf.key}}"
cmd="\${cmd//\/run\/user\/\\\$(id -u)/$t/run}"
if [[ -n \${STUB_EXTRA_SAN:-} && \$cmd == *"step certificate create"* ]]; then cmd="\${cmd/ >\/dev\/null/ --san evil.example >/dev/null}"; fi
exec bash -c "\$cmd"
EOF
  cat >"$t/bin/incus" <<EOF
#!/usr/bin/env bash
if [[ "\$1 \$2" == "cluster update-certificate" ]]; then cp "\$3" "$t/served.crt"; touch "$t/updated"; fi
exit 0
EOF
  printf '#!/usr/bin/env bash\nexit 0\n' >"$t/bin/systemctl"
  chmod +x "$t/bin/"*
  touch "$t/operator" "$t/operator-cert.pub"

  script="$t/renew.sh"
  {
    echo 'set -euo pipefail'
    echo "keysYaml=$t/keys.yaml authority=test-tls cn=m1 via=m1 remote=m1 days=365"
    echo "sshUser=op sshKey=$t/operator sshCert=$t/operator-cert.pub"
    echo 'sans=(m1 m2) members=(m1 m2) verifyNames=(m1 m2)'
    cat "${BATS_TEST_DIRNAME}/../incus-cluster-cert-renew.sh"
  } >"$script"
}

run_renew() { HOME="$t/home" XDG_STATE_HOME="$t/state" PATH="$t/bin:$PATH" run bash "$script" "$@"; }

@test "--dry-run with every member OK reaches the signature and stops there" {
  run_renew --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"RENEW:"* ]]
  [[ $output == *"DRY RUN: would certify"* ]]
}

@test "--check that finds a renewal exits 10, never 1" {
  run_renew --check
  [ "$status" -eq 10 ]
  [[ $output == *"RENEW:"* ]]
}

@test "a preflight ERROR stops the run before anything is signed" {
  STUB_SSH_ERROR=1 run_renew --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"preflight found 2 error(s)"* ]]
  [[ $output != *"would certify"* ]]
}

@test "a member that serves nothing is ABSENT, exit 2, with its message" {
  STUB_ABSENT=1 run_renew --check
  [ "$status" -eq 2 ]
  [[ $output == *"ABSENT: no certificate served on m1 m2"* ]]
}

# X1: a trace prints every value it expands, the CA private included. The test CA key is a real
# "-----BEGIN PRIVATE KEY-----", so a leak would show.
@test "under bash -x, the trace says xtrace is off and carries no private key" {
  HOME="$t/home" XDG_STATE_HOME="$t/state" PATH="$t/bin:$PATH" run bash -x "$script" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"xtrace disabled"* ]]
  [[ $output != *"PRIVATE KEY"* ]]
}

@test "an exported SHELLOPTS=xtrace is disabled too" {
  # SHELLOPTS is readonly in this shell: set it for the CHILD, as an inherited environment would.
  HOME="$t/home" XDG_STATE_HOME="$t/state" PATH="$t/bin:$PATH" run env SHELLOPTS=xtrace bash "$script" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"xtrace disabled"* ]]
  [[ $output != *"PRIVATE KEY"* ]]
}

@test "the xtrace guard is the SAME block in every script that handles a private" {
  local here="${BATS_TEST_DIRNAME}/.." f
  guard() { sed -n '/^# ★ xtrace-guard/,/^unset BASH_XTRACEFD/p' "$1"; }
  [ -n "$(guard "$here/incus-cluster-cert-renew.sh")" ]
  for f in ssh-keys.d/ssh-enrich-keys-yaml.sh ssh-keys-renew.d/ssh-keys-renew.sh \
    ssh-keys-certify.d/ssh-keys-certify.sh \
    cache-signing-key-rotate.d/cache-signing-key-rotate.sh \
    authority-bootstrap-tls-root.d/authority-bootstrap-tls-root.sh ../home-manager/git.d/sops.sh; do
    [ "$(guard "$here/../$f")" = "$(guard "$here/incus-cluster-cert-renew.sh")" ]
  done
}

pub() { # <x509|pkey> <file> → the sha256 of its public key
  if [[ $1 == pkey ]]; then "$realOpenssl" pkey -in "$2" -pubout; else "$realOpenssl" x509 -in "$2" -noout -pubkey; fi |
    "$realOpenssl" sha256
}

@test "a renewal certifies the member's EXISTING key with the pinned profile, and records it" {
  mkdir -p "$t/tmp"
  TMPDIR="$t/tmp" run_renew
  [ "$status" -eq 0 ]
  [ -e "$t/updated" ]
  # The served leaf is new, signed by the current root, and still on the key the member held.
  "$realOpenssl" verify -CAfile "$t/current.crt" "$t/served.crt" >/dev/null
  [ "$(pub x509 "$t/served.crt")" = "$(pub pkey "$t/leaf.key")" ]
  text="$("$realOpenssl" x509 -in "$t/served.crt" -noout -text)"
  [[ $text == *"CA:FALSE"* ]]
  [[ $text == *"TLS Web Server Authentication"* ]]
  [[ $text != *"TLS Web Client Authentication"* ]]
  ls "$t/state/ndh/incus-cluster-cert/"*.crt >/dev/null
  # No private key is left anywhere the run wrote: its work dir, the member's tmpfs dir.
  run ! grep -rl 'PRIVATE KEY' "$t/tmp" "$t/run"
}

@test "a CSR naming one more SAN than the fleet's is refused, and nothing is installed" {
  STUB_EXTRA_SAN=1 run_renew
  [ "$status" -eq 1 ]
  [[ $output == *"does not name exactly the fleet's SANs"* ]]
  [ ! -e "$t/updated" ]
}

@test "a CSR on another key than the one the cluster serves is refused" {
  "$realOpenssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$t/other.key" 2>/dev/null
  STUB_CLUSTER_KEY="$t/other.key" run_renew
  [ "$status" -eq 1 ]
  [[ $output == *"is not the key m1 serves"* ]]
  [ ! -e "$t/updated" ]
}

@test "an expiry date alone renews by hand, never at activation" {
  "$realOpenssl" req -new -key "$t/leaf.key" -subj "/CN=m1" -addext "subjectAltName=DNS:m1,DNS:m2" -out "$t/near.csr" 2>/dev/null
  "$realOpenssl" x509 -req -in "$t/near.csr" -CA "$t/current.crt" -CAkey "$t/current.key" -CAcreateserial \
    -copy_extensions copy -out "$t/served.crt" -days 10 2>/dev/null
  run_renew --check
  [ "$status" -eq 10 ]
  [[ $output == *"expires within 30 days"* ]]
  run_renew --activation
  [ "$status" -eq 0 ]
  [[ $output == *"CURRENT"* ]]
  [ ! -e "$t/updated" ]
}

@test "an absent cluster at activation is a warning, and the activation goes on" {
  STUB_ABSENT=1 run_renew --activation
  [ "$status" -eq 0 ]
  [[ $output == *"WARN: no certificate served"* ]]
}
