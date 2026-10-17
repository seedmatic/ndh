#!/usr/bin/env bats
# ndh-nix-signing-key with the real deriver on a throwaway host key: placed 0400 in a 0700 directory by a rename,
# refused without a trace when the derived public is not the recorded one, and the previous key then untouched.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${NIX_SIGNING_DERIVE:?the ndh-nix-signing-derive binary}"
  ssh-keygen -q -t ed25519 -N "" -C host -f "$t/host"
  args=(--name seedmatic-test-1 --label seedmatic/nix-signing/1)
  public="$("$NIX_SIGNING_DERIVE" "${args[@]}" --public <"$t/host")"
  render "$public"
}

render() { # <recorded public>
  {
    printf '#!%s\nset -euo pipefail\n' "$BASH"
    printf 'derive=%q hostKeyFile=%q name=seedmatic-test-1 label=seedmatic/nix-signing/1 recorded=%q dir=%q\n' \
      "$NIX_SIGNING_DERIVE" "$t/host" "$1" "$t/var/nix-signing"
    cat "$BATS_TEST_DIRNAME/../place.sh"
  } >"$t/place"
  chmod +x "$t/place"
}

mode() { stat -c %a "$1" 2>/dev/null || stat -f %Lp "$1"; }

@test "the key is placed 0400 in a 0700 directory, as the deriver's secret, and nothing else is left" {
  run --separate-stderr "$t/place"
  [ "$status" -eq 0 ]
  [ "$(mode "$t/var/nix-signing")" = 700 ]
  [ "$(mode "$t/var/nix-signing/seedmatic-test-1.sec")" = 400 ]
  cmp "$t/var/nix-signing/seedmatic-test-1.sec" <("$NIX_SIGNING_DERIVE" "${args[@]}" --secret <"$t/host")
  [ "$(find "$t/var/nix-signing" -type f | wc -l)" -eq 1 ]
  [[ $output$stderr != *"$(cut -d: -f2 "$t/var/nix-signing/seedmatic-test-1.sec")"* ]]
}

@test "a derived key that is not the recorded one is refused, and the previous key stays as it was" {
  "$t/place"
  before="$(sha256sum "$t/var/nix-signing/seedmatic-test-1.sec")"
  render "seedmatic-test-1:$(head -c 32 /dev/urandom | base64)"
  run "$t/place"
  [ "$status" -eq 1 ]
  [[ $output == *"is not the seedmatic-test-1 keys.yaml records"* ]]
  [ "$(sha256sum "$t/var/nix-signing/seedmatic-test-1.sec")" = "$before" ]
  [ "$(find "$t/var/nix-signing" -type f | wc -l)" -eq 1 ]
}

@test "without the host key nothing is derived or written" {
  rm "$t/host"
  run "$t/place"
  [ "$status" -eq 1 ]
  [[ $output == *"no host key at"* ]]
  [ ! -e "$t/var/nix-signing" ]
}
