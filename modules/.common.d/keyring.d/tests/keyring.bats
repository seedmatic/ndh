#!/usr/bin/env bats
#
# ndh-keyring on its REAL path: the real generator, the real pass and gpg, a throwaway GnuPG home with a
# test key whose encryption subkey plays the seedmatic subkey, and a throwaway store. pass is wrapped only
# to record HOW it received the key: on stdin, never as an argument (argv is visible in ps).

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  here="${BATS_TEST_DIRNAME}/.."
  export GNUPGHOME="$t/gnupg" PASSWORD_STORE_DIR="$t/store" HOME="$t/home"
  mkdir -p "$GNUPGHOME" "$HOME" "$t/bin" "$t/tmp" && chmod 700 "$GNUPGHOME"
  gpg --batch --quiet --passphrase '' --pinentry-mode loopback --quick-gen-key seedmatic@test default default never 2>/dev/null
  gpg --batch --quiet --passphrase '' --pinentry-mode loopback --quick-gen-key personal@test default default never 2>/dev/null
  sub() { gpg --list-keys --with-colons "$1" | awk -F: '$1 == "sub" { print $5; exit }'; }
  seedmatic="$(sub seedmatic@test)"
  personal="$(sub personal@test)"
  pass init "$personal" >/dev/null
  pass init -p seedmatic "${seedmatic}!" >/dev/null

  realPass="$(command -v pass)"
  cat >"$t/bin/pass" <<EOF
#!/usr/bin/env bash
printf '%s\n' "\$*" >>"$t/pass.argv"
exec "$realPass" "\$@"
EOF
  chmod +x "$t/bin/pass"
  {
    printf 'set -euo pipefail\n'
    printf 'machines=(bioskop nikopol bioskop-nixos nikopol-nixos) recipient=%s generate=%q\n' \
      "$seedmatic" "$t/gen"
    cat "$here/ndh-keyring.sh"
  } >"$t/keyring"
  printf '#!/usr/bin/env bash\nexec python3 -I %q\n' "$here/gen-ed25519.py" >"$t/gen"
  chmod +x "$t/gen"
}

keyring() { TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/keyring" "$@"; }
entry() { printf '%s' "$PASSWORD_STORE_DIR/seedmatic/host-key/$1.gpg"; }

@test "a host key is generated into seedmatic/, to the seedmatic subkey alone, and its public printed" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" host-key bioskop-nixos
  [ "$status" -eq 0 ]
  [[ $output == "ssh-ed25519 "*" host-bioskop-nixos" ]]
  # The printed public is the stored key's.
  [ "$(printf '%s\n' "$output" | ssh-to-age)" = "$(pass show seedmatic/host-key/bioskop-nixos | ssh-to-age -private-key | age-keygen -y)" ]
  # Exactly one recipient, the seedmatic subkey.
  run gpg --batch --list-only --list-packets "$(entry bioskop-nixos)"
  [ "$(grep -c ':pubkey enc packet:' <<<"$output")" -eq 1 ]
  [[ $output == *"keyid ${seedmatic}"* ]]
}

@test "the private never appears in the output, an argument or a scratch dir" {
  keyring host-key bioskop
  [ "$status" -eq 0 ]
  [[ $output != *"PRIVATE KEY"* ]]
  ! grep -q 'PRIVATE KEY' "$t/pass.argv"
  grep -qx 'insert -m seedmatic/host-key/bioskop' "$t/pass.argv"
  [ -z "$(find "$t/tmp" -type f)" ]
}

@test "an existing entry is never overwritten" {
  keyring host-key bioskop
  before="$(sha256sum "$(entry bioskop)")"
  keyring host-key bioskop
  [ "$status" -eq 1 ]
  [[ $output == *"never overwritten"* ]]
  [ "$(sha256sum "$(entry bioskop)")" = "$before" ]
}

@test "a machine outside the inventory is refused" {
  keyring host-key corp-mac
  [ "$status" -eq 1 ]
  [[ $output == *"not one of the inventory's machines"* ]]
  [ ! -e "$PASSWORD_STORE_DIR/seedmatic/host-key" ]
}

@test "a seedmatic/.gpg-id other than the subkey, pinned, is refused before generating" {
  printf '%s\n' "$seedmatic" >"$PASSWORD_STORE_DIR/seedmatic/.gpg-id" # without the !
  keyring host-key bioskop
  [ "$status" -eq 1 ]
  [[ $output == *"is not exactly ${seedmatic}!"* ]]
  [ ! -e "$(entry bioskop)" ]
}

@test "a lost seedmatic/.gpg-id (the store root's personal keys would apply) is refused" {
  rm -f "$PASSWORD_STORE_DIR/seedmatic/.gpg-id"
  keyring host-key bioskop
  [ "$status" -eq 1 ]
  [ ! -e "$(entry bioskop)" ]
}

@test "a nearer .gpg-id under seedmatic/host-key is refused before generating" {
  pass init -p seedmatic/host-key "${seedmatic}!" "$personal" >/dev/null
  keyring host-key bioskop
  [ "$status" -eq 1 ]
  [[ $output == *"would override the seedmatic recipient"* ]]
  [ ! -e "$(entry bioskop)" ]
}

@test "a machine name with a space is refused, never split into an entry" {
  keyring host-key "bioskop nikopol"
  [ "$status" -eq 1 ]
  [[ $output == *"not one of the inventory's machines"* ]]
  [ ! -e "$PASSWORD_STORE_DIR/seedmatic/host-key" ]
}

@test "a recipient override in the environment is refused before generating" {
  PASSWORD_STORE_KEY="$personal" keyring host-key bioskop
  [ "$status" -eq 1 ]
  [[ $output == *"would override the seedmatic recipient"* ]]
  PASSWORD_STORE_GPG_OPTS="--recipient $personal" keyring host-key bioskop
  [ "$status" -eq 1 ]
  [ ! -e "$(entry bioskop)" ]
}

@test "under bash -x, the trace says xtrace is off and carries no private" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash -x "$t/keyring" host-key bioskop
  [ "$status" -eq 0 ]
  [[ $output == *"[xtrace-guard] xtrace disabled"* ]]
  [[ $output != *"PRIVATE KEY"* ]]
}
