#!/usr/bin/env bats
#
# ndh-attic-tokens-receive on its real path: real age ciphertext made here, a throwaway store, the unseal stubbed
# to record that it ran.

bats_require_minimum_version 1.5.0

setup() {
  t=$BATS_TEST_TMPDIR
  store=$t/store
  age-keygen -o "$t/identity" 2>/dev/null
  printf 'machine attic.m1\npassword a.b.c\n' | age -r "$(age-keygen -y "$t/identity")" -o "$t/netrc.m1.age"
  printf 'w.x.y' | age -r "$(age-keygen -y "$t/identity")" -o "$t/write.token.age"
  printf '#!%s\ntouch %q\n' "$BASH" "$t/unsealed" >"$t/unseal" && chmod +x "$t/unseal"
  {
    printf 'set -euo pipefail\n'
    printf 'machine=bioskop-nixos store=%q maxBytes=65536 unseal=%q\n' "$store" "$t/unseal"
    printf 'declare -A cacheFqdn=([m1]=attic.m1 [m2]=attic.m2)\n'
    cat "$BATS_TEST_DIRNAME/../receive.sh"
  } >"$t/receive"
}

item() { printf 'item %s %s\n' "${2:-$(basename "$1")}" "$(base64 <"$1" | tr -d '\n')"; }
frame() {
  printf 'ndh-attic-tokens/1 %s\n' "${1:-bioskop-nixos}"
  item "$t/netrc.m1.age"
  item "$t/write.token.age"
  printf 'end\n'
}
receive() { run --separate-stderr bash "$t/receive"; }
nothing_written() { [ -z "$(find "$store" -type f 2>/dev/null)" ] && [ ! -e "$t/unsealed" ]; }

@test "a frame for this machine keeps each item at rest, byte for byte, then unseals" {
  receive < <(frame)
  [ "$status" -eq 0 ]
  cmp "$store/netrc.m1.age" "$t/netrc.m1.age"
  cmp "$store/write.token.age" "$t/write.token.age"
  [ -e "$t/unsealed" ]
  [ -z "$(find "$store" -name '.receive.*')" ]
}

@test "the previous generation of each item is kept as .prev, one generation" {
  receive < <(frame)
  cp "$store/netrc.m1.age" "$t/first"
  printf 'machine attic.m1\npassword d.e.f\n' | age -r "$(age-keygen -y "$t/identity")" -o "$t/netrc.m1.age"
  receive < <(frame)
  [ "$status" -eq 0 ]
  cmp "$store/netrc.m1.age.prev" "$t/first"
  cmp "$store/netrc.m1.age" "$t/netrc.m1.age"
}

@test "a frame addressed to another machine writes nothing" {
  receive < <(frame nikopol-nixos)
  [ "$status" -eq 1 ]
  [[ $stderr == *"a frame not addressed to bioskop-nixos"* ]]
  nothing_written
}

@test "an item for a metalspace outside the catalog, or not a token item, writes nothing" {
  receive < <(printf 'ndh-attic-tokens/1 bioskop-nixos\n'; item "$t/netrc.m1.age" netrc.m9.age; printf 'end\n')
  [ "$status" -eq 1 ]
  [[ $stderr == *"no metalspace m9 in the catalog"* ]]
  receive < <(printf 'ndh-attic-tokens/1 bioskop-nixos\n'; item "$t/netrc.m1.age" authorized_keys; printf 'end\n')
  [ "$status" -eq 1 ]
  [[ $stderr == *"authorized_keys: not a token item"* ]]
  nothing_written
}

@test "an item that is not age ciphertext, or comes twice, writes nothing, not even the valid items" {
  printf 'plain text\nsecond line\n' >"$t/plain"
  receive < <(printf 'ndh-attic-tokens/1 bioskop-nixos\n'; item "$t/netrc.m1.age"; item "$t/plain" write.token.age; printf 'end\n')
  [ "$status" -eq 1 ]
  [[ $stderr == *"write.token.age is not age ciphertext to an X25519 identity"* ]]
  receive < <(printf 'ndh-attic-tokens/1 bioskop-nixos\n'; item "$t/netrc.m1.age"; item "$t/netrc.m1.age"; printf 'end\n')
  [ "$status" -eq 1 ]
  [[ $stderr == *"netrc.m1.age twice"* ]]
  nothing_written
}

@test "a frame over the size bound, or without its end, writes nothing" {
  receive < <(frame; head -c 70000 /dev/zero | tr '\0' a)
  [ "$status" -eq 1 ]
  [[ $stderr == *"a frame over 65536 bytes"* ]]
  receive < <(printf 'ndh-attic-tokens/1 bioskop-nixos\n'; item "$t/netrc.m1.age")
  [ "$status" -eq 1 ]
  nothing_written
}
