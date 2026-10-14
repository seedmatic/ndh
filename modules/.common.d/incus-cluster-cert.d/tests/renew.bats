#!/usr/bin/env bats
#
# incus-cluster-cert-renew on its REAL path, up to the mint: classification, preflight, and the
# exit contract. A run that stops silently on an all-OK preflight looked normal because --check
# also exited 1 there; --dry-run reaching "would mint" is what proves the path is open.
#
# Only the outside world is stubbed, first on PATH: sops (a test keys.yaml with a real CA),
# `openssl s_client` (a leaf from an OLD test CA, so the cluster needs RENEW; every other openssl
# subcommand runs the real one) and ssh (the preflight probe's answer).

setup() {
  realOpenssl="$(command -v openssl)"
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/home"

  ca() { # <name> — a self-signed P-256 test root
    "$realOpenssl" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$t/$1.key" -out "$t/$1.crt" -subj "/CN=test-tls" -days 30 2>/dev/null
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
  echo "Verification error: unable to verify the first certificate"
  exit 0
fi
exec "$realOpenssl" "\$@"
EOF
  cat >"$t/bin/ssh" <<'EOF'
#!/usr/bin/env bash
if [[ -n ${STUB_SSH_ERROR:-} ]]; then
  echo "ERROR /run/wrappers/bin/sudo is not the setuid sudo: must be owned by uid 0"
else
  echo "OK /run/wrappers/bin/sudo runs without a password"
fi
echo "OK incus on PATH"
echo "OK /run/user/501 present (tmpfs)"
EOF
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

run_renew() { HOME="$t/home" PATH="$t/bin:$PATH" run bash "$script" "$@"; }

@test "--dry-run with every member OK reaches the mint and stops there" {
  run_renew --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"RENEW:"* ]]
  [[ $output == *"DRY RUN: would mint"* ]]
}

@test "--check that finds a renewal exits 10, never 1" {
  run_renew --check
  [ "$status" -eq 10 ]
  [[ $output == *"RENEW:"* ]]
}

@test "a preflight ERROR stops the run before anything is minted" {
  STUB_SSH_ERROR=1 run_renew --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"preflight found 2 error(s)"* ]]
  [[ $output != *"would mint"* ]]
}

@test "a member that serves nothing is ABSENT, exit 2, with its message" {
  STUB_ABSENT=1 run_renew --check
  [ "$status" -eq 2 ]
  [[ $output == *"ABSENT: no certificate served on m1 m2"* ]]
}

# X1: a trace prints every value it expands, the CA private included. The test CA key is a real
# "-----BEGIN PRIVATE KEY-----", so a leak would show.
@test "under bash -x, the trace says xtrace is off and carries no private key" {
  HOME="$t/home" PATH="$t/bin:$PATH" run bash -x "$script" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"xtrace disabled"* ]]
  [[ $output != *"PRIVATE KEY"* ]]
}

@test "an exported SHELLOPTS=xtrace is disabled too" {
  # SHELLOPTS is readonly in this shell: set it for the CHILD, as an inherited environment would.
  HOME="$t/home" PATH="$t/bin:$PATH" run env SHELLOPTS=xtrace bash "$script" --dry-run
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
