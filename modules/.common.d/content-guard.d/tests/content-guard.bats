#!/usr/bin/env bats
#
# content-guard: every secret shape is refused, its look-alikes pass, and only the refused paths are
# printed — never what matched.

setup() {
  t="$BATS_TEST_TMPDIR"
  script="${BATS_TEST_DIRNAME}/../content-guard.sh"
  mk() { # <name> <content>
    mkdir -p "$t/$1"
    printf '%s\n' "$2" >"$t/$1/file"
  }
  mk age "token AGE-SECRET-KEY-1$(printf 'Q%.0s' {1..58})"
  mk jwt "password eyJ$(printf 'a%.0s' {1..12}).eyJ$(printf 'b%.0s' {1..12}).$(printf 'c%.0s' {1..12})"
  mk ghp "ghp_$(printf 'x%.0s' {1..36})"
  mk armour "$(printf -- '-----BEGIN OPENSSH PRIVATE KEY-----\n%s' "$(printf 'b%.0s' {1..64})")"
  mk sopsbad "$(printf '# sops:encrypted\nprivate: hunter2')"
  mk akia "key=AKIA$(printf 'Z%.0s' {1..16})"
  mk awssecret "aws_secret_access_key = $(printf 'w%.0s' {1..40})"
  mk nixsecret "secret-key = seedmatic-test-1:$(printf 'A%.0s' {1..86})=="
  mk nixpublic "trusted-public-keys = seedmatic-test-1:$(printf 'A%.0s' {1..43})="
  mk header "$(printf -- 'grep for -----BEGIN OPENSSH PRIVATE KEY-----\nto tell a key file')"
  mk sopsok "$(printf '# sops:encrypted\nprivate: ENC[AES256_GCM,data:x]')"
  mk doc "the AKIA prefix names an access key; set aws_secret_access_key = <yours>"
  mk clean "nothing to see"
}

guard() { run bash -euo pipefail "$script" "$@"; }

@test "every secret shape is refused" {
  for p in age jwt ghp armour sopsbad akia awssecret nixsecret; do
    guard "$t/$p"
    [ "$status" -eq 1 ]
    [ "$output" = "refused $t/$p" ]
  done
}

@test "the look-alikes pass" {
  guard "$t/header" "$t/sopsok" "$t/doc" "$t/nixpublic" "$t/clean"
  [ "$status" -eq 0 ]
  [ -z "$output" ]
}

@test "one refused path fails the whole call, and only it is named" {
  guard "$t/clean" "$t/akia" "$t/doc"
  [ "$status" -eq 1 ]
  [ "$output" = "refused $t/akia" ]
}

@test "what matched is never printed" {
  guard "$t/age" "$t/awssecret"
  [[ $output != *AGE-SECRET* ]]
  [[ $output != *wwwwwwwwww* ]]
}

@test "a missing path or no argument is an error, not a pass" {
  guard "$t/none"
  [ "$status" -eq 2 ]
  guard
  [ "$status" -eq 2 ]
}
