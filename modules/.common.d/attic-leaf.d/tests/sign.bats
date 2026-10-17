#!/usr/bin/env bats
#
# attic-leaf-sign on its REAL path: classification, preflight, the exit contract, the CSR's
# refusals, and a full signature through to the served leaf.
#
# Only the outside world is stubbed, first on PATH: sops (it answers the one-slot extract only),
# `openssl s_client` (serves $t/served.crt, or nothing; every other openssl subcommand runs the real
# one) and ssh (the guest: its CSR, the preflight probe's answer, the install into $t/served.crt).

setup() {
  realOpenssl="$(command -v openssl)"
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin" "$t/home"

  ca() { # <name> — a self-signed P-256 test root
    "$realOpenssl" req -x509 -newkey ec -pkeyopt ec_paramgen_curve:P-256 -nodes \
      -keyout "$t/$1.key" -out "$t/$1.crt" -subj "/CN=test-tls" -days 30 \
      -addext "basicConstraints=critical,CA:TRUE" -addext "keyUsage=critical,keyCertSign,cRLSign" 2>/dev/null
  }
  ca current
  ca old
  # The cache container's key and the CSR attic-tls-key writes beside it.
  "$realOpenssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$t/cache.key" 2>/dev/null
  csr() { # <out> <san list> — a CSR on the cache's key
    "$realOpenssl" req -new -key "$t/cache.key" -subj "/CN=attic.m1" -addext "subjectAltName=$2" -out "$1" 2>/dev/null
  }
  csr "$t/request.csr" "DNS:attic.m1"
  # What attic.m1 serves today: a leaf on the same key, from the OLD root.
  "$realOpenssl" x509 -req -in "$t/request.csr" -CA "$t/old.crt" -CAkey "$t/old.key" \
    -CAcreateserial -out "$t/served.crt" -days 30 2>/dev/null

  # As the real one: the metadata and ca_crt in clear, the private ENC[] — only sops holds it.
  CA="$(<"$t/current.crt")" yq --null-input '
    {"authorities": {"test-tls": {"usage": ["tls-authority"],
      "slots": {"26-10-10": {"ca_crt": strenv(CA), "private": "ENC[AES256_GCM,data:test,type:str]"}}}}}' >"$t/keys.yaml"

  # sops answers ONLY the signing step's one-slot extract, and records every call: any other call,
  # on any path, exits 97 (the no-decrypt shape shared with ssh-keys-certify and S6).
  cat >"$t/bin/sops" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$t/sops.calls"
[[ "\$*" == '--decrypt --extract ["authorities"]["test-tls"]["slots"]["26-10-10"]["private"] $t/keys.yaml' ]] || exit 97
if [[ -n \${STUB_SOPS_FAIL:-} ]]; then echo "SOPS-STDERR-MARKER: no identity matched" >&2; exit 128; fi
cat "$t/current.key"
EOF
  cat >"$t/bin/openssl" <<EOF
#!$BASH
if [[ \$1 == s_client ]]; then
  [[ -s "$t/served.crt" ]] || exit 1
  echo CONNECTED
  cat "$t/served.crt"
  if "$realOpenssl" verify -CAfile "$t/current.crt" "$t/served.crt" >/dev/null 2>&1; then
    echo "Verification: OK"
  else
    echo "Verification error: unable to verify the first certificate"
  fi
  exit 0
fi
exec "$realOpenssl" "\$@"
EOF
  # The guest, by the remote command it is given (the last argument).
  cat >"$t/bin/ssh" <<EOF
#!$BASH
# Every session runs with the operator's ssh config ignored, and never prompts.
args=" \$* "
for o in "-F /dev/null " "BatchMode=yes " "PasswordAuthentication=no " "KbdInteractiveAuthentication=no " \\
  "StrictHostKeyChecking=yes "; do
  [[ \$args == *"\$o"* ]] || { echo "ssh stub: missing \$o" >&2; exit 97; }
done
cmd="\${@: -1}"
case "\$cmd" in
  # The preflight probe first: its text contains the other patterns.
  *"sh -c"*)
    if [[ -n \${STUB_SSH_ERROR:-} ]]; then echo "ERROR /run/wrappers/bin/sudo is not the setuid sudo: must be owned by uid 0"
    else echo "OK /run/wrappers/bin/sudo runs without a password"; fi
    echo "OK /tls/request.csr present"; echo "OK /tls writable"; echo "OK /run/user/501 present (tmpfs)" ;;
  *"test -s"*) [[ -s "$t/request.csr" && -z \${STUB_NO_CSR:-} ]] ;;
  *"cat '/tls/request.csr'"*) cat "$t/request.csr" ;;
  *mktemp*) mkdir -p "$t/remote" && echo "$t/remote" ;;
  *"cat > "*) cat >"$t/remote/leaf.crt" ;;
  *install*) cp "$t/remote/leaf.crt" "$t/served.crt" ;;
  *"rm -rf"*) rm -rf "$t/remote" ;;
  *) echo "unexpected remote command: \$cmd" >&2; exit 99 ;;
esac
EOF
  chmod +x "$t/bin/"*
  touch "$t/operator" "$t/operator-cert.pub"
  # The log sink: a file the cases read, instead of the host's unified log or journald.
  export LOGGER_CMD="tee -a $t/sink"

  script="$t/sign.sh"
  write_script 'fqdns=(attic.m1) vias=(nixos.m1)'
}

write_script() { # <the caches' arrays>
  {
    echo 'set -euo pipefail'
    echo "source ${BATS_TEST_DIRNAME}/../../shell.d/logger.sh"
    echo 'loggerTag=test.attic-leaf'
    echo "toolPath=$t/bin:$PATH"
    echo "keysYaml=$t/keys.yaml authority=test-tls days=365 hostTls=/tls"
    echo "sshUser=op sshKey=$t/operator sshCert=$t/operator-cert.pub"
    echo "$1"
    cat "${BATS_TEST_DIRNAME}/../attic-leaf-sign.sh"
  } >"$script"
}

# Every run is confined to the test's own directory: a run whose state could land in the operator's
# real home (a test leaf once did, through an inherited XDG_STATE_HOME) refuses to start.
isolated() { # <cmd>... — runs <cmd> with HOME and XDG_STATE_HOME under $BATS_TMPDIR, or fails
  local home="$t/home" state="$t/home/.local/state"
  [[ $home == "$BATS_TMPDIR"/* && $state == "$BATS_TMPDIR"/* ]] || {
    echo "refusing: HOME or XDG_STATE_HOME is not under BATS_TMPDIR" >&2
    return 1
  }
  HOME="$home" XDG_STATE_HOME="$state" PATH="$t/bin:$PATH" "$@"
}
run_sign() { run isolated bash "$script" "$@"; }
# <file> holds no line of the test CA's private (its PEM armour excepted).
no_ca_key_in() {
  local l
  [[ $1 != *"PRIVATE KEY"* ]] || return 1
  while IFS= read -r l; do
    [[ $l == -----* ]] && continue
    [[ $1 != *"$l"* ]] || return 1
  done <"$t/current.key"
}

@test "no NixOS guest declares a cache: nothing to sign, exit 0" {
  write_script 'fqdns=() vias=()'
  run_sign --check
  [ "$status" -eq 0 ]
  [[ $output == *"nothing to sign"* ]]
}

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
  hostile run_sign --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"DRY RUN: would certify attic.m1"* ]]
  [[ $output != *hostile-* ]]
}

@test "--dry-run on a leaf of another root reaches the signature and stops there" {
  run_sign --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"SIGN:"* ]]
  [[ $output == *"does not chain"* ]]
  [[ $output == *"DRY RUN: would certify attic.m1"* ]]
}

@test "--check that finds a leaf to sign exits 10, never 1" {
  run_sign --check
  [ "$status" -eq 10 ]
}

@test "a first leaf: nothing served, the CSR held — it is signed, even at activation" {
  rm "$t/served.crt"
  run_sign --check
  [ "$status" -eq 10 ]
  [[ $output == *"serves no leaf yet"* ]]
  run_sign --activation --dry-run
  [ "$status" -eq 0 ]
  [[ $output == *"DRY RUN: would certify attic.m1"* ]]
}

@test "nothing served and no CSR is ABSENT: exit 2, and a warning at activation" {
  rm "$t/served.crt"
  STUB_NO_CSR=1 run_sign --check
  [ "$status" -eq 2 ]
  [[ $output == *"ABSENT: no leaf served and no CSR held for attic.m1"* ]]
  STUB_NO_CSR=1 run_sign --activation
  [ "$status" -eq 0 ]
  [[ $output == *"WARN"* ]]
}

@test "a preflight ERROR stops the run before anything is signed" {
  STUB_SSH_ERROR=1 run_sign --dry-run
  [ "$status" -eq 1 ]
  [[ $output == *"preflight found 1 error(s)"* ]]
  [[ $output != *"would certify"* ]]
}

@test "a CSR naming more than the cache is refused, nothing signed" {
  csr "$t/request.csr" "DNS:attic.m1,DNS:attic.m2"
  run_sign
  [ "$status" -eq 1 ]
  [[ $output == *"does not name exactly attic.m1"* ]]
  [ ! -d "$t/home/.local/state/ndh/attic-leaf" ] || [ -z "$(ls "$t/home/.local/state/ndh/attic-leaf")" ]
}

@test "a CSR on another key than the served one is refused, nothing signed" {
  "$realOpenssl" genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$t/cache.key" 2>/dev/null
  csr "$t/request.csr" "DNS:attic.m1"
  run_sign
  [ "$status" -eq 1 ]
  [[ $output == *"CSR key is not the key it serves"* ]]
}

@test "the full path signs, records and serves exactly the signed leaf, by the pinned profile" {
  run_sign
  [ "$status" -eq 0 ]
  [[ $output == *"ok   attic.m1: serves the signed leaf"* ]]
  ledgerFile="$(ls "$t/home/.local/state/ndh/attic-leaf/"*.crt)"
  grep -q '^# signed .* by test-tls@26-10-10 for attic.m1$' "$ledgerFile"
  text="$("$realOpenssl" x509 -in "$t/served.crt" -noout -text)"
  [[ $text == *"Digital Signature"* && $text != *"Key Encipherment"* ]]
  [[ $text == *"TLS Web Server Authentication"* && $text != *"Client Authentication"* ]]
  [[ $text == *"CA:FALSE"* ]]
  [[ "$("$realOpenssl" x509 -in "$t/served.crt" -noout -ext subjectAltName | tail -1 | tr -d ' ')" == "DNS:attic.m1" ]]
  # One leaf signed, one sops call: the extract of that slot's private.
  [ "$(wc -l <"$t/sops.calls")" -eq 1 ]
  run_sign --check
  [ "$status" -eq 0 ]
  [[ $output == *"CURRENT"* ]]
  [ "$(wc -l <"$t/sops.calls")" -eq 1 ]
}

@test "no path that signs nothing calls sops: --check, --dry-run, a refused CSR, nothing to sign" {
  run_sign --check
  [ "$status" -eq 10 ]
  run_sign --dry-run
  [ "$status" -eq 0 ]
  run_sign --activation --dry-run
  [ "$status" -eq 0 ]
  csr "$t/request.csr" "DNS:attic.m1,DNS:attic.m2"
  run_sign
  [ "$status" -eq 1 ]
  [ ! -e "$t/sops.calls" ]
}

@test "a failed sops extract says so, and its text never reaches the output" {
  STUB_SOPS_FAIL=1 run_sign
  [ "$status" -eq 1 ]
  [[ $output == *"sops decrypt of test-tls@26-10-10 failed (exit 128)"* ]]
  [[ $output != *"SOPS-STDERR-MARKER"* ]]
  run ! grep -q 'SOPS-STDERR-MARKER' "$t/sink"
}

@test "the log sink says whether a run decrypted: never on --dry-run, once on a signature" {
  run_sign --dry-run
  [ "$status" -eq 0 ]
  grep -q '^\[test.attic-leaf\] .*nothing decrypted' "$t/sink"
  run ! grep -q 'the only decryption of this run' "$t/sink"
  : >"$t/sink"
  run_sign
  [ "$status" -eq 0 ]
  [ "$(grep -c '^\[test.attic-leaf\] .*the only decryption of this run' "$t/sink")" -eq 1 ]
}

@test "the sink carries neither the age key's path, nor a private, nor a trace — even asked to trace" {
  SOPS_AGE_KEY_FILE="$t/AGE-KEY-MARKER" NDH_LOGGER_XTRACE=1 run_sign
  [ "$status" -eq 0 ]
  [ -s "$t/sink" ]
  run ! grep -q 'AGE-KEY-MARKER' "$t/sink"
  run ! grep -q 'PRIVATE KEY' "$t/sink"
  run ! grep -qE '^\[test\.attic-leaf\] \+' "$t/sink"
}

@test "a ca_crt that is not cleartext fails closed, before anything" {
  yq -i '.authorities."test-tls".slots."26-10-10".ca_crt = "ENC[AES256_GCM,data:x,type:str]"' "$t/keys.yaml"
  run_sign --check
  [ "$status" -eq 1 ]
  [[ $output == *"has no cleartext ca_crt"* ]]
  [ ! -e "$t/sops.calls" ]
}

@test "a session that would read the operator's ssh config is refused by the stub" {
  sed -i 's| -F /dev/null | |' "$script"
  run_sign
  [ "$status" -ne 0 ]
  [[ $output == *"ssh stub: missing -F /dev/null"* ]]
}

# X1 / R1: a trace prints every value it expands, the CA private included — on the FULL path, the
# signature too. The test CA key is real, so a leak of any of its lines would show.
@test "under bash -x, the full path says xtrace is off and carries no line of the CA private" {
  run isolated bash -x "$script"
  [ "$status" -eq 0 ]
  [[ $output == *"xtrace disabled"* ]]
  [[ $output == *"serves the signed leaf"* ]]
  no_ca_key_in "$output"
}

@test "an exported SHELLOPTS=xtrace is disabled too, on the full path" {
  run isolated env SHELLOPTS=xtrace bash "$script"
  [ "$status" -eq 0 ]
  [[ $output == *"xtrace disabled"* ]]
  no_ca_key_in "$output"
}

@test "the leak check bites: a key held in the shell under an xtrace is caught" {
  sed -i 's|^  step certificate sign "\$work/\$i.csr" "\$work/ca.crt" \\$|  caKey="$(sops --decrypt --extract "[\\"authorities\\"][\\"${authority}\\"][\\"slots\\"][\\"${slot}\\"][\\"private\\"]" "$keysYaml")"; set -x; : "$caKey"\n&|' "$script"
  grep -q 'set -x; : "\$caKey"' "$script"
  run_sign
  ! no_ca_key_in "$output"
}

@test "an xtrace at the signing step prints no key: it never enters the shell" {
  sed -i 's|^  step certificate sign "\$work/\$i.csr" "\$work/ca.crt" \\$|  set -x\n&|' "$script"
  grep -q '^  set -x$' "$script"
  run_sign
  [ "$status" -eq 0 ]
  no_ca_key_in "$output"
}

@test "there is no trace mode: --debug is refused" {
  run_sign --debug
  [ "$status" -eq 1 ]
  [[ $output == *"usage: attic-leaf-sign"* ]]
}
