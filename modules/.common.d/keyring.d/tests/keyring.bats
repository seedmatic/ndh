#!/usr/bin/env bats
#
# ndh-keyring on its REAL path: the real generator, the real pass and gpg, a throwaway GnuPG home with a
# test key whose encryption subkey plays the seedmatic subkey, and a throwaway store. pass is wrapped only
# to record HOW it received the key: on stdin, never as an argument (argv is visible in ps).

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  # The stubs run under the bats bash itself: the darwin build sandbox refuses to exec /usr/bin/env.
  shebang="#!$BASH"
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

  vzOptions='restrict,command="/Users/corp/.nix-profile/bin/ndh-vz-recover"'
  realPass="$(command -v pass)"
  cat >"$t/bin/pass" <<EOF
$shebang
printf '%s\n' "\$*" >>"$t/pass.argv"
exec "$realPass" "\$@"
EOF
  chmod +x "$t/bin/pass"
  {
    printf 'set -euo pipefail\n'
    printf 'machines=(bioskop nikopol bioskop-nixos nikopol-nixos) guests=(bioskop-nixos nikopol-nixos)\n'
    printf 'vzHosts=(nikopol)\ndeclare -A vzRecoverOptions=([nikopol]=%q)\n' "$vzOptions"
    printf 'recipient=%s generate=%q derive=%q nixSigningVersion=1\n' \
      "$seedmatic" "$t/gen" "${NIX_SIGNING_DERIVE:?the ndh-nix-signing-derive binary}"
    cat "$here/ndh-keyring.sh"
  } >"$t/keyring"
  printf '%s\nexec python3 -I %q\n' "$shebang" "$here/gen-ed25519.py" >"$t/gen"
  chmod +x "$t/gen"
}

keyring() { TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run bash "$t/keyring" "$@"; }
entry() { printf '%s' "$PASSWORD_STORE_DIR/seedmatic/${2:-host-key}/$1.gpg"; }

@test "a host key is generated into seedmatic/, to the seedmatic subkey alone, and its public printed" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" host-key bioskop-nixos
  [ "$status" -eq 0 ]
  [[ $output == "ssh-ed25519 "*" bioskop-nixos" ]]
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
  ! grep -q 'PRIVATE KEY' "$t/pass.argv" || false
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

@test "nix-signing-public prints the public derived from the keyring's host key, and writes nothing" {
  keyring host-key bioskop
  before="$(find "$PASSWORD_STORE_DIR" -type f -exec sha256sum {} + | LC_ALL=C sort)"
  : >"$t/pass.argv"
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" nix-signing-public bioskop
  [ "$status" -eq 0 ]
  [[ $output =~ ^seedmatic-bioskop-1:[A-Za-z0-9+/]{43}=$ ]]
  [[ $stderr == *"ssh-keys-renew --record-nix-signing bioskop --public -"* ]]
  # The deriver run directly on the same host key gives the same line (it refuses one equal to the host key).
  [ "$output" = "$(pass show seedmatic/host-key/bioskop |
    "$NIX_SIGNING_DERIVE" --name seedmatic-bioskop-1 --label seedmatic/nix-signing/1 --public)" ]
  [ "$(find "$PASSWORD_STORE_DIR" -type f -exec sha256sum {} + | LC_ALL=C sort)" = "$before" ]
  [ "$(<"$t/pass.argv")" = "show seedmatic/host-key/bioskop" ]
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [ -z "$(find "$t/tmp" -type f)" ]
}

@test "nix-signing-public without the machine's host key in the keyring derives nothing" {
  keyring nix-signing-public nikopol
  [ "$status" -eq 1 ]
  [[ $output == *"seedmatic/host-key/nikopol is not in the keyring"* ]]
  [[ $output != *"seedmatic-nikopol-1:"* ]]
}

@test "nix-signing-public is for the inventory's machines only" {
  keyring nix-signing-public corp-mac
  [ "$status" -eq 1 ]
  [[ $output == *"not one of the inventory's machines"* ]]
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

@test "an unknown kind is a usage error, and generates nothing" {
  keyring user-key bioskop-nixos
  [ "$status" -eq 1 ]
  [[ $output == *"usage: ndh-keyring host-key <machine> | vz-recover-key <host>"* ]]
  [ -z "$(find "$PASSWORD_STORE_DIR/seedmatic" -name '*.gpg')" ]
}

@test "a vz-recover key is generated into seedmatic/vz-recover-key/, installed 0600, and its line printed on stderr" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" vz-recover-key nikopol
  [ "$status" -eq 0 ]
  # stdout is the one public line ssh-keys-renew --public - records.
  [[ $output == "ssh-ed25519 "*" vz-recover-nikopol" ]]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  read -r _ blob _ <<<"$output"
  [ "$(pass show seedmatic/vz-recover-key/nikopol | ssh-to-age -private-key | age-keygen -y)" = "$(printf '%s\n' "$output" | ssh-to-age)" ]
  [ "$(stat -c %a "$HOME/.ssh/vz-recover" 2>/dev/null || stat -f %Lp "$HOME/.ssh/vz-recover")" = 600 ]
  [ "$(ssh-keygen -y -f "$HOME/.ssh/vz-recover" | awk '{ print $2 }')" = "$blob" ]
  grep -qxF "$vzOptions ssh-ed25519 $blob vz-recover-nikopol" <<<"$stderr"
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [ ! -e "$HOME/.ssh/vz-recover.new" ]
}

@test "a vz-recover key is for a foreign vz-host only, and generates nothing otherwise" {
  for name in bioskop nikopol-nixos elsewhere; do
    keyring vz-recover-key "$name"
    [ "$status" -eq 1 ]
    [[ $output == *"not one of the inventory's foreign vz-hosts"* ]]
  done
  [ ! -e "$PASSWORD_STORE_DIR/seedmatic/vz-recover-key" ] && [ ! -e "$HOME/.ssh/vz-recover" ]
}

@test "an installed vz-recover file is never overwritten: refused before anything is generated" {
  mkdir -p "$HOME/.ssh" && printf 'kept\n' >"$HOME/.ssh/vz-recover"
  keyring vz-recover-key nikopol
  [ "$status" -eq 1 ]
  [[ $output == *"never overwritten"* ]]
  [ ! -e "$(entry nikopol vz-recover-key)" ]
  [ "$(<"$HOME/.ssh/vz-recover")" = kept ]
}

@test "a cluster-age identity is generated into seedmatic/, to the seedmatic subkey alone; stdout is its age public only" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" cluster-age 1
  [ "$status" -eq 0 ]
  [[ $output =~ ^age1[0-9a-z]+$ ]]
  [ "$(wc -l <<<"$output")" -eq 1 ]
  # The printed public is the stored identity's.
  [ "$(pass show seedmatic/cluster-age/1 | age-keygen -y)" = "$output" ]
  run gpg --batch --list-only --list-packets "$(entry 1 cluster-age)"
  [ "$(grep -c ':pubkey enc packet:' <<<"$output")" -eq 1 ]
  [[ $output == *"keyid ${seedmatic}"* ]]
}

@test "the cluster-age private never appears in stdout, stderr, an argument or a scratch dir" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" cluster-age 1
  [ "$status" -eq 0 ]
  [[ $output$stderr != *"AGE-SECRET-KEY"* ]]
  # stderr carries the logs and no age material but the public stdout already printed.
  ! grep -o 'age1[0-9a-z]*' <<<"$stderr" | grep -vxF "$output" || false
  ! grep -q 'AGE-SECRET-KEY' "$t/pass.argv" || false
  grep -qx 'insert -m seedmatic/cluster-age/1' "$t/pass.argv"
  [ -z "$(find "$t/tmp" -type f)" ]
}

@test "an existing cluster-age version is never overwritten; a new version is a new key" {
  keyring cluster-age 1
  before="$(sha256sum "$(entry 1 cluster-age)")"
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" cluster-age 1
  [ "$status" -eq 1 ]
  [[ $stderr == *"never overwritten"* ]]
  [[ $output$stderr != *"AGE-SECRET-KEY"* ]]
  [ "$(sha256sum "$(entry 1 cluster-age)")" = "$before" ]
  keyring cluster-age 2
  [ "$status" -eq 0 ]
  [ "$(pass show seedmatic/cluster-age/2 | age-keygen -y)" != "$(pass show seedmatic/cluster-age/1 | age-keygen -y)" ]
}

@test "a cluster-age version is a positive integer, and nothing is generated otherwise" {
  for name in 0 -1 01 one bioskop 1a ''; do
    keyring cluster-age "$name"
    [ "$status" -eq 1 ]
    [[ $output == *"positive integer"* ]]
  done
  [ ! -e "$PASSWORD_STORE_DIR/seedmatic/cluster-age" ]
}

@test "cluster-age-public prints the stored identity's public again, and writes nothing" {
  keyring cluster-age 1
  generated="$(pass show seedmatic/cluster-age/1 | age-keygen -y)"
  before="$(find "$PASSWORD_STORE_DIR" -type f -exec sha256sum {} + | LC_ALL=C sort)"
  : >"$t/pass.argv"
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" cluster-age-public 1
  [ "$status" -eq 0 ]
  [ "$output" = "$generated" ]
  [[ $output$stderr != *"AGE-SECRET-KEY"* ]]
  [ "$(find "$PASSWORD_STORE_DIR" -type f -exec sha256sum {} + | LC_ALL=C sort)" = "$before" ]
  [ "$(<"$t/pass.argv")" = "show seedmatic/cluster-age/1" ]
}

@test "cluster-age-public of a version not in the keyring is refused" {
  TMPDIR="$t/tmp" PATH="$t/bin:$PATH" run --separate-stderr bash "$t/keyring" cluster-age-public 3
  [ "$status" -eq 1 ]
  [[ $stderr == *"not in the keyring"* ]]
  [ -z "$output" ]
}
