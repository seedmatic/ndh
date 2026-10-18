#!/usr/bin/env bats
# ndh-ceremony init with a stand-in seedmatic key: only ciphertext and publics leave, each private encrypted to ONE
# subkey, the statements verify against the root, the intermediate chains to it, and nothing is overwritten.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${ATTEST:?the ndh-root-attest binary}"
  export GNUPGHOME="$t/operator-gnupg"
  mkdir -m 0700 "$GNUPGHOME"
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-generate-key "stand-in <s@x.invalid>" ed25519 cert never 2>/dev/null
  fpr="$(gpg --batch --with-colons --list-keys s@x.invalid | awk -F: '/^fpr:/ { print $10; exit }')"
  gpg --batch --pinentry-mode loopback --passphrase "" --quick-add-key "$fpr" cv25519 encr never 2>/dev/null
  recipient="$(gpg --batch --with-colons --list-keys "$fpr" | awk -F: '$1 == "sub" { print $5; exit }')"
  mkdir -p "$t/in" "$t/out"
  gpg --batch --armor --export "$fpr" >"$t/in/seedmatic.asc"
  printf 'one two three four five six seven\n' >"$t/passphrase"
  {
    printf '#!%s\nset -euo pipefail\n' "$BASH"
    printf 'in=%q out=%q work=%q passphraseFrom=%q attest=%q recipient=%q\n' \
      "$t/in" "$t/out" "$t/work" "$t/passphrase" "$ATTEST" "$recipient"
    cat "$BATS_TEST_DIRNAME/../ndh-ceremony.sh"
  } >"$t/ceremony"
  chmod +x "$t/ceremony"
}

keyids() { gpg --batch --list-only --list-packets "$1" 2>/dev/null | sed -n 's/^:pubkey enc packet:.* keyid \([0-9A-Fa-f]*\).*/\1/p'; }

@test "init writes ciphertext and publics only, each private to ONE subkey, and leaves nothing in RAM's place" {
  run --separate-stderr env GNUPGHOME= "$t/ceremony" init
  [ "$status" -eq 0 ]
  [ ! -e "$t/work" ]
  for f in root.gpg fabric-ssh-host.gpg fabric-ssh-user.gpg mammoth-skate-tls.gpg root-gpg.sec.asc; do [ -s "$t/out/$f" ]; done
  ! grep -l -r -E 'PRIVATE KEY-----' "$t/out" || false
  [ "$(keyids "$t/out/fabric-ssh-host.gpg")" = "$recipient" ]
  [ "$(keyids "$t/out/mammoth-skate-tls.gpg")" = "$recipient" ]
  [ "$(keyids "$t/out/root.gpg" | wc -l)" -eq 1 ]
  [ "$(keyids "$t/out/root.gpg")" != "$recipient" ]
}

@test "both statements verify against the root, and the intermediate chains to it" {
  env GNUPGHOME= "$t/ceremony" init 2>/dev/null
  root="$(cut -d' ' -f1,2 "$t/out/seedmatic-root.pub")"
  for u in host user; do
    run --separate-stderr "$ATTEST" verify --root "$root" --statement "$t/out/fabric-ssh-$u.statement" \
      --signature "$t/out/fabric-ssh-$u.statement.sig" --name "fabric-ssh-$u" --usage "ssh-$u" \
      --key "$(cut -d' ' -f1,2 "$t/out/fabric-ssh-$u.pub")"
    [ "$status" -eq 0 ]
  done
  openssl verify -CAfile "$t/out/seedmatic-root.crt" "$t/out/mammoth-skate-tls.crt"
  grep -q '^root ssh SHA256:' "$t/out/ceremony.log"
  grep -q '^fabric-ssh-user SHA256:.* until ' "$t/out/ceremony.log"
}

@test "the root's own ciphertext opens only with its passphrase" {
  env GNUPGHOME= "$t/ceremony" init 2>/dev/null
  export GNUPGHOME="$t/restore"
  mkdir -m 0700 "$GNUPGHOME"
  gpg --batch --pinentry-mode loopback --passphrase "one two three four five six seven" \
    --import "$t/out/root-gpg.sec.asc" 2>/dev/null
  ! gpg --batch --pinentry-mode loopback --passphrase "wrong" --decrypt "$t/out/root.gpg" >/dev/null 2>&1 || false
  gpg --batch --pinentry-mode loopback --passphrase "one two three four five six seven" \
    --decrypt "$t/out/root.gpg" 2>/dev/null | head -1 | grep -q 'BEGIN EC PRIVATE KEY'
}

@test "a short passphrase, a missing seedmatic public or a non-empty out is refused, and nothing is written" {
  printf 'too short\n' >"$t/passphrase"
  run --separate-stderr env GNUPGHOME= "$t/ceremony" init
  [ "$status" -eq 1 ]
  [[ $stderr == *"7 or more"* ]]
  [ -z "$(ls -A "$t/out")" ]
  printf 'one two three four five six seven\n' >"$t/passphrase"
  rm "$t/in/seedmatic.asc"
  run --separate-stderr env GNUPGHOME= "$t/ceremony" init
  [ "$status" -eq 1 ]
  gpg --batch --armor --export "$fpr" >"$t/in/seedmatic.asc"
  touch "$t/out/leftover"
  run --separate-stderr env GNUPGHOME= "$t/ceremony" init
  [ "$status" -eq 1 ]
  [[ $stderr == *"empty directory"* ]]
}
