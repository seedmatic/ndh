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
  # The log sink: a file the cases read, instead of the host's unified log or journald.
  export LOGGER_CMD="tee -a $t/sink"

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

  # The ONE decryption the script may make: one slot's private, by --extract. Every call is recorded,
  # and anything else (a whole-file --decrypt) fails, so a run that should sign nothing proves it
  # never reached the operator's age key.
  cat >"$t/bin/sops" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$t/sops.calls"
[[ \$1 == --decrypt && \$2 == --extract ]] || { echo "sops stub: only --decrypt --extract of one slot" >&2; exit 97; }
[[ -z \${STUB_SOPS_FAIL:-} ]] || { echo "SOPS-STDERR-MARKER: Failed to get the data key" >&2; exit 128; }
yq -r ".\$(printf '%s' "\$3" | sed -e 's/^\[//' -e 's/\]\$//' -e 's/\]\[/./g')" "\$4"
EOF
  cat >"$t/bin/openssl" <<EOF
#!$BASH
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
#!$BASH
# Every session runs with the operator's ssh config ignored, and never prompts.
args=" \$* "
for o in "-F /dev/null " "BatchMode=yes " "PasswordAuthentication=no " "KbdInteractiveAuthentication=no " \\
  "StrictHostKeyChecking=yes "; do
  [[ \$args == *"\$o"* ]] || { echo "ssh stub: missing \$o" >&2; exit 97; }
done
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
#!$BASH
if [[ "\$1 \$2" == "cluster update-certificate" ]]; then cp "\$3" "$t/served.crt"; touch "$t/updated"; fi
exit 0
EOF
  printf '#!%s\nexit 0\n' "$BASH" >"$t/bin/systemctl"
  chmod +x "$t/bin/"*
  touch "$t/operator" "$t/operator-cert.pub"

  script="$t/renew.sh"
  {
    echo 'set -euo pipefail'
    echo "source ${BATS_TEST_DIRNAME}/../../shell.d/logger.sh"
    echo 'loggerTag=test.incus-cluster-cert'
    echo "toolPath=$t/bin:$PATH"
    echo "keysYaml=$t/keys.yaml authority=test-tls cn=m1 via=m1 remote=m1 days=365"
    echo "sshUser=op sshKey=$t/operator sshCert=$t/operator-cert.pub"
    echo 'sans=(m1 m2) members=(m1 m2) verifyNames=(m1 m2)'
    cat "${BATS_TEST_DIRNAME}/../incus-cluster-cert-renew.sh"
  } >"$script"
}

run_renew() { HOME="$t/home" XDG_STATE_HOME="$t/state" PATH="$t/bin:$PATH" run bash "$script" "$@"; }

# A caller's shell at its worst: failing tools first on PATH, a UTF-8 locale and POSIXLY_CORRECT.
hostile() { # <cmd>... — runs <cmd> under it
  local d="$BATS_TEST_TMPDIR/hostile" c
  mkdir -p "$d"
  for c in yq awk gawk sort tr paste cut sed grep diff sops ssh ssh-keygen openssl step git; do
    printf '#!%s\necho hostile-%s >&2\nexit 1\n' "$BASH" "$c" >"$d/$c" && chmod +x "$d/$c"
  done
  PATH="$d:$PATH" LANG=fr_FR.UTF-8 LC_ALL=fr_FR.UTF-8 LC_COLLATE=fr_FR.UTF-8 POSIXLY_CORRECT=1 "$@"
}

@test "a caller's PATH, locale and POSIXLY_CORRECT change nothing, and none of its tools ran" {
  hostile run_renew --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"DRY RUN: would certify"* ]]
  [[ $output != *hostile-* ]]
  [ ! -e "$t/sops.calls" ]
}

@test "--dry-run with every member OK reaches the signature and stops there" {
  run_renew --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"RENEW:"* ]]
  [[ $output == *"DRY RUN: would certify"* ]]
  [ ! -e "$t/sops.calls" ]
}

@test "--check that finds a renewal exits 10, never 1" {
  run_renew --check
  [ "$status" -eq 10 ]
  [[ $output == *"RENEW:"* ]]
  [ ! -e "$t/sops.calls" ]
}

@test "a renewal decrypts exactly once: the signing slot's private, by --extract" {
  mkdir -p "$t/tmp"
  TMPDIR="$t/tmp" run_renew
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$t/sops.calls")" -eq 1 ]
  [[ $(<"$t/sops.calls") == '--decrypt --extract ["authorities"]["test-tls"]["slots"]["26-10-10"]["private"] '* ]]
}

@test "the log sink says whether a run decrypted: never on --dry-run, once on a renewal" {
  run_renew --dry-run
  [ "$status" -eq 0 ]
  grep -q '^\[test.incus-cluster-cert\] .*nothing decrypted' "$t/sink"
  run ! grep -q 'the only decryption of this run' "$t/sink"
  mkdir -p "$t/tmp"
  : >"$t/sink"
  TMPDIR="$t/tmp" run_renew
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[test.incus-cluster-cert\] .*the only decryption of this run' "$t/sink")" -eq 1 ]
}

@test "the sink carries neither the age key's path, nor a private, nor a trace — even asked to trace" {
  mkdir -p "$t/tmp"
  SOPS_AGE_KEY_FILE="$t/AGE-KEY-MARKER" NDH_LOGGER_XTRACE=1 TMPDIR="$t/tmp" run_renew
  [ "$status" -eq 0 ]
  SOPS_AGE_KEY_FILE="$t/AGE-KEY-MARKER" NDH_LOGGER_XTRACE=1 HOME="$t/home" XDG_STATE_HOME="$t/state" \
    PATH="$t/bin:$PATH" run bash -x "$script" --dry-run
  [ "$status" -eq 0 ]
  [ -s "$t/sink" ]
  run ! grep -q 'AGE-KEY-MARKER' "$t/sink"
  run ! grep -q 'PRIVATE KEY' "$t/sink"
  run ! grep -qE '^\[test\.incus-cluster-cert\] \+' "$t/sink"
}

# The logger traces by default: the script re-runs itself inside it, and its guard's NDH_LOGGER_XTRACE=0 is what
# keeps that run untraced, end to end, with no request either way.
@test "by default, no trace reaches the sink: the guard opts the logged re-run out" {
  mkdir -p "$t/tmp"
  unset NDH_LOGGER_XTRACE
  SOPS_AGE_KEY_FILE="$t/AGE-KEY-MARKER" TMPDIR="$t/tmp" run_renew
  [ "$status" -eq 0 ]
  [ -s "$t/sink" ]
  run ! grep -q 'PRIVATE KEY' "$t/sink"
  run ! grep -qE '^\[test\.incus-cluster-cert\] \+' "$t/sink"
}

@test "a failed decryption reports sops' exit status only, never its stderr" {
  mkdir -p "$t/tmp"
  STUB_SOPS_FAIL=1 TMPDIR="$t/tmp" run_renew
  [ "$status" -eq 1 ]
  [[ $output == *"sops decrypt of test-tls@26-10-10 failed (exit 128)"* ]]
  [[ $output != *"SOPS-STDERR-MARKER"* ]]
  run ! grep -q 'SOPS-STDERR-MARKER' "$t/sink"
  [ ! -e "$t/updated" ]
}

@test "a ca_crt read as ENC[…] is refused before anything is decrypted" {
  yq -i '.authorities."test-tls".slots."26-10-10".ca_crt = "ENC[AES256_GCM,data:x,type:str]"' "$t/keys.yaml"
  run_renew --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"cleartext-metadata contract changed"* ]]
  [ ! -e "$t/sops.calls" ]
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

@test "there is no trace mode: --debug is refused before anything is read" {
  run_renew --debug
  [ "$status" -eq 1 ]
  [[ $output == *"usage:"* ]]
  [ ! -e "$t/updated" ]
}

@test "a full renewal under bash -x, with an inherited BASH_XTRACEFD, traces no private" {
  mkdir -p "$t/tmp"
  HOME="$t/home" XDG_STATE_HOME="$t/state" TMPDIR="$t/tmp" BASH_XTRACEFD=2 PATH="$t/bin:$PATH" \
    run bash -x "$script"
  [ "$status" -eq 0 ]
  [ -e "$t/updated" ]
  [[ $output == *"xtrace disabled"* ]]
  [[ $output != *"PRIVATE KEY"* ]]
  [[ $output != *"$(sed -n 2p "$t/current.key")"* ]]
}

@test "an exported SHELLOPTS=xtrace is disabled too" {
  # SHELLOPTS is readonly in this shell: set it for the CHILD, as an inherited environment would.
  HOME="$t/home" XDG_STATE_HOME="$t/state" PATH="$t/bin:$PATH" run env SHELLOPTS=xtrace bash "$script" --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"xtrace disabled"* ]]
  [[ $output != *"PRIVATE KEY"* ]]
}

@test "the xtrace guard is the SAME block in every script that handles a private throughout" {
  local here="${BATS_TEST_DIRNAME}/.." f
  # The same block, but for what the script handles (private keys, cache tokens), named in its two messages.
  guard() { sed -n '/^# ★ xtrace-guard/,/^unset BASH_XTRACEFD/p' "$1" | sed -E 's/this script handles (private keys|cache tokens)/this script handles <secret>/'; }
  [ -n "$(guard "$here/incus-cluster-cert-renew.sh")" ]
  for f in authority-bootstrap-tls-root.d/authority-bootstrap-tls-root.sh ../home-manager/git.d/sops.sh \
    keyring.d/ndh-keyring.sh ../nixos/attic-cache.d/token-issue.sh keys-yaml.d/krl.sh \
    attic-tokens.d/unseal.sh; do
    [ "$(guard "$here/../$f")" = "$(guard "$here/incus-cluster-cert-renew.sh")" ] || { echo "${f}: not the same guard" >&2; return 1; }
  done
}

# The scripts on the trampoline hold their secrets in local windows instead (guard-before-flip): no whole-script block,
# the trampoline sourced, so secret-xtrace-guard judges every line of them strictly (unwindowed, guard-before-flip),
# and a window wherever one holds a secret value. ssh-keys-certify holds none: its private goes sops → ssh-add by a pipe.
@test "the trampoline scripts that handle a private carry no whole-script guard, and their windows" {
  local here="${BATS_TEST_DIRNAME}/.." f want
  for f in ssh-keys.d/ssh-enrich-keys-yaml.sh=2 ssh-keys-renew.d/ssh-keys-renew.sh=3 \
    cache-signing-key-rotate.d/cache-signing-key-rotate.sh=3 ssh-keys-certify.d/ssh-keys-certify.sh=0; do
    want=${f#*=} f=${f%=*}
    [ -s "$here/../$f" ] || { echo "${f}: not found" >&2; return 1; }
    if grep -q '^# ★ xtrace-guard\|^case \$- in \*x\*)' "$here/../$f"; then echo "${f}: a whole-script guard" >&2; return 1; fi
    grep -qE '^source "?@nixBashTrampoline@"?' "$here/../$f" || { echo "${f}: not on the trampoline" >&2; return 1; }
    [ "$(grep -c '^[[:space:]]*ndh::secret:begin ' "$here/../$f")" -eq "$want" ] || { echo "${f}: not ${want} window(s)" >&2; return 1; }
    [ "$(grep -c '^[[:space:]]*ndh::secret:end$' "$here/../$f")" -eq "$want" ] || { echo "${f}: not ${want} close(s)" >&2; return 1; }
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
  # serverAuth alone is Incus's own cluster profile (shared/tls/cert.go): members request a peer's
  # certificate without verifying its usage (tls.RequestClientCert) and trust it by fingerprint.
  eku="$("$realOpenssl" x509 -in "$t/served.crt" -noout -ext extendedKeyUsage | sed -n 2p | tr -d ' ')"
  [ "$eku" = "TLSWebServerAuthentication" ]
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
  # Neither the check nor an activation with nothing due ever reaches the age key.
  [ ! -e "$t/sops.calls" ]
}

@test "an absent cluster at activation is a warning, and the activation goes on" {
  STUB_ABSENT=1 run_renew --activation
  [ "$status" -eq 0 ]
  [[ $output == *"WARN: no certificate served"* ]]
  [ ! -e "$t/sops.calls" ]
}
