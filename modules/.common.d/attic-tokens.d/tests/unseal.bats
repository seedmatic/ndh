#!/usr/bin/env bats
#
# ndh-attic-tokens-unseal on its real path: real age and ssh-to-age, identities and ciphertext made here, a
# throwaway store and tmpfs dir.

bats_require_minimum_version 1.5.0

setup() {
  t=$BATS_TEST_TMPDIR
  store=$t/store dir=$t/run/ndh-attic
  mkdir -p "$store"
  ssh-keygen -q -t ed25519 -N '' -C host -f "$t/host"
  recipient="$(ssh-to-age -i "$t/host.pub")"
  header "$t/host" >"$t/unseal"
}

header() { # <identity> [writeTokenOwner]
  printf 'set -euo pipefail\n'
  printf 'store=%q dir=%q netrc=%q writeToken=%q identity=%q writeTokenOwner=%q\n' \
    "$store" "$dir" "$dir/netrc" "$dir/write.token" "$1" "${2:-root}"
  printf 'declare -A cacheFqdn=([m1]=attic.m1 [m2]=attic.m2)\n'
  cat "$BATS_TEST_DIRNAME/../unseal.sh"
}

seal() { # <file> <clear text> [recipient]
  printf '%s' "$2" | age -r "${3:-$recipient}" -o "$1"
}
read_fragment() { printf 'machine attic.%s\npassword %s.%s.%s\n' "$1" "head$1" "body$1" "sig$1"; }
mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }
unseal() { run --separate-stderr bash "$t/unseal"; }
no_token_in_output() { [[ $output$stderr != *body* && $output$stderr != *wbody* ]]; }

@test "every cache's fragment and the write token are unsealed into the tmpfs dir, 0400, by this machine's host key" {
  seal "$store/netrc.m1.age" "$(read_fragment m1)"
  seal "$store/netrc.m2.age" "$(read_fragment m2)"
  seal "$store/write.token.age" "whead.wbody.wsig"
  unseal
  [ "$status" -eq 0 ]
  [ "$(<"$dir/netrc")" = "$(read_fragment m1; read_fragment m2)" ]
  [ "$(<"$dir/write.token")" = whead.wbody.wsig ]
  [ "$(mode "$dir/netrc")" = 400 ]
  [ "$(mode "$dir/write.token")" = 400 ]
  [ "$(mode "$dir")" = 700 ]
  [[ $stderr == *"read tokens of attic.m1 attic.m2, and the write token"* ]]
  no_token_in_output
  [ -z "$(find "$dir" -name '.unseal.*')" ]
}

@test "a write token owner other than root gets write.token, the dir lets it through but not list, netrc stays put" {
  # The sandbox is not root: the build user stands for the watch-store's account.
  header "$t/host" "$(id -un)" >"$t/unseal"
  seal "$store/netrc.m1.age" "$(read_fragment m1)"
  seal "$store/write.token.age" "whead.wbody.wsig"
  unseal
  [ "$status" -eq 0 ]
  [ "$(stat -c %U "$dir/write.token" 2>/dev/null || stat -f %Su "$dir/write.token")" = "$(id -un)" ]
  [ "$(mode "$dir/write.token")" = 400 ]
  [ "$(mode "$dir/netrc")" = 400 ]
  [ "$(mode "$dir")" = 711 ]
  no_token_in_output
}

@test "mutant: a token sealed to another machine's key (its seat's) does not unseal" {
  ssh-keygen -q -t ed25519 -N '' -C seat -f "$t/seat"
  seal "$store/netrc.m1.age" "$(read_fragment m1)" "$(ssh-to-age -i "$t/seat.pub")"
  unseal
  [ "$status" -ne 0 ]
  [ ! -e "$dir/netrc" ]
}

@test "nothing delivered: nothing to do, nothing created" {
  unseal
  [ "$status" -eq 0 ]
  [[ $stderr == *"nothing to unseal"* ]]
  [ ! -e "$dir" ]
}

@test "a current generation that does not decrypt falls back to the previous one, loudly" {
  printf 'garbage\n' >"$store/netrc.m1.age"
  seal "$store/netrc.m1.age.prev" "$(read_fragment m1)"
  unseal
  [ "$status" -eq 0 ]
  [ "$(<"$dir/netrc")" = "$(read_fragment m1)" ]
  [[ $stderr == *"WARNING: netrc.m1.age does not decrypt or check; its previous generation is used"* ]]
}

@test "a fragment naming another cache falls back to the previous one" {
  seal "$store/netrc.m1.age" "$(read_fragment m2)"
  seal "$store/netrc.m1.age.prev" "$(read_fragment m1)"
  unseal
  [ "$status" -eq 0 ]
  [ "$(<"$dir/netrc")" = "$(read_fragment m1)" ]
}

@test "with no good generation the run fails, and the tokens in place stay as they are" {
  mkdir -p "$dir" && printf 'kept\n' >"$dir/netrc"
  seal "$store/netrc.m1.age" $'machine attic.m1\npassword not-a-jwt'
  unseal
  [ "$status" -eq 1 ]
  [[ $stderr == *"neither it nor its previous generation decrypts to a netrc fragment for attic.m1"* ]]
  [ "$(<"$dir/netrc")" = kept ]
  [ -z "$(find "$dir" -name '.unseal.*')" ]
}

@test "a write token that is not one token fails the run, and nothing is replaced" {
  seal "$store/netrc.m1.age" "$(read_fragment m1)"
  seal "$store/write.token.age" "$(printf 'a.b.c\nd.e.f')"
  unseal
  [ "$status" -eq 1 ]
  [[ $stderr == *"write.token.age: neither it nor its previous generation"* ]]
  [ ! -e "$dir/netrc" ]
  [ ! -e "$dir/write.token" ]
}

@test "a fragment for a metalspace the catalog does not name fails the run" {
  seal "$store/netrc.m9.age" "$(read_fragment m9)"
  unseal
  [ "$status" -eq 1 ]
  [[ $stderr == *"netrc.m9.age: no metalspace m9 in the catalog"* ]]
  [ ! -e "$dir/netrc" ]
}
