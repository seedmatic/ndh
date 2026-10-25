#!/usr/bin/env bats
#
# attic-token-mint, in the cache container: every token is minted with the declared validity (twice the mint period),
# a read token pulls only, only this metalspace's machines get a write token, each target's files land in its hashed
# directory (no machine name served), a failed mint leaves the previous generation served, and no token reaches the
# output. atticd-atticadm, ssh-to-age and age are stubbed: atticadm records each call and prints a fake token, age
# writes what it is fed.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin"
  cat >"$t/bin/atticd-atticadm" <<EOF
#!$BASH
printf '%s\n' "\$*" >>"$t/calls"
[ ! -e "$t/fail" ] || exit 1
while [ \$# -gt 0 ]; do case "\$1" in --sub) sub="\$2"; shift 2 ;; *) shift ;; esac; done
printf 'TOKEN-FOR-%s' "\$sub"
EOF
  cat >"$t/bin/ssh-to-age" <<EOF
#!$BASH
cat >/dev/null
printf 'age1stubrecipient\n'
EOF
  cat >"$t/bin/age" <<EOF
#!$BASH
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
cat >"\$out"
EOF
  chmod +x "$t/bin/"*
  script="${BATS_TEST_DIRNAME}/../token-mint.sh"
  d1=$(printf 'a%.0s' {1..64}) d2=$(printf 'b%.0s' {1..64}) d3=$(printf 'c%.0s' {1..64})
  export CACHE_FQDN=attic.m1 METALSPACE=m1 CACHE_NAME=seedmatic VALIDITY='14 days'
  export TARGETS="m1 m1 $d1 ssh-ed25519 AAAA1
m1-nixos m1 $d2 ssh-ed25519 AAAA2
m2 m2 $d3 ssh-ed25519 AAAA3"
}

mint() { PATH="$t/bin:$PATH" run --separate-stderr bash -euo pipefail "$script" "$t/out"; }

@test "every token is minted with the declared validity, and no other" {
  mint
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$t/calls")" -eq 5 ]
  [ "$(grep -c -- '--validity 14 days ' "$t/calls")" -eq 5 ]
}

@test "a read token pulls only; a write token pushes and pulls; another metalspace never writes" {
  mint
  [ "$(grep -c -- '--validity 14 days --pull seedmatic$' "$t/calls")" -eq 3 ]
  [ "$(grep -c -- '--push seedmatic --pull seedmatic$' "$t/calls")" -eq 2 ]
  run grep -- '--sub m2 .*--push' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "each target's files land in its hashed directory, and no directory is named after a machine" {
  mint
  [ -f "$t/out/$d1/netrc.m1.age" ]
  [ -f "$t/out/$d1/write.token.age" ]
  [ -f "$t/out/$d2/netrc.m1.age" ]
  [ -f "$t/out/$d2/write.token.age" ]
  [ -f "$t/out/$d3/netrc.m1.age" ]
  [ ! -e "$t/out/$d3/write.token.age" ]
  [ "$(cat "$t/out/$d3/netrc.m1.age")" = $'machine attic.m1\npassword TOKEN-FOR-m2' ]
  run ls "$t/out"
  [[ $output != *m1* && $output != *m2* ]]
  [ "$(stat -c %a "$t/out/$d1/netrc.m1.age")" = 644 ]
}

@test "a served directory that is not a sha256 is refused, nothing minted" {
  export TARGETS="m1 m1 ../etc ssh-ed25519 AAAA1"
  mint
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a sha256"* ]]
  [ ! -e "$t/calls" ]
}

@test "a failed mint keeps the previous generation served, and leaves no partial file" {
  mint
  before="$(cat "$t/out/$d1/netrc.m1.age")"
  touch "$t/fail"
  mint
  [ "$status" -ne 0 ]
  [ "$(cat "$t/out/$d1/netrc.m1.age")" = "$before" ]
  run find "$t/out" -name '*.age.new'
  [ -z "$output" ]
}

@test "no machine to mint for is refused" {
  export TARGETS=""
  mint
  [ "$status" -ne 0 ]
  [[ $stderr == *"no machine to mint for"* ]]
}

@test "traced, no token reaches the output or the trace" {
  PATH="$t/bin:$PATH" bash -x "$script" "$t/out" >"$t/stdout" 2>"$t/trace"
  run grep -q TOKEN-FOR "$t/stdout" "$t/trace"
  [ "$status" -eq 1 ]
}
