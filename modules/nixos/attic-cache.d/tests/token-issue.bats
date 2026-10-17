#!/usr/bin/env bats
#
# attic-token-issue: every token is minted with the one far validity (attic cannot omit the expiry;
# tokens end only when the cache's token-signing secret rotates), a read token pulls only, and only
# this metalspace's machines get a write token. incus, ssh-to-age and age are stubbed: incus records
# each make-token call and prints a fake token, age writes what it is fed.

setup() {
  t="$BATS_TEST_TMPDIR"
  mkdir -p "$t/bin"
  cat >"$t/bin/incus" <<EOF
#!$BASH
shift 6 # --project P exec --cwd / INSTANCE
[ "\$1" = -- ] && shift
printf '%s\n' "\$*" >>"$t/calls"
printf 'TOKEN-FOR-%s' "\$4"
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
  script="${BATS_TEST_DIRNAME}/../token-issue.sh"
  export CACHE_FQDN=attic.m1 METALSPACE=m1 CACHE_NAME=seedmatic PROJECT=ndh INSTANCE=attic
  export TARGETS=$'m1 m1 ssh-ed25519 AAAA1\nm1-nixos m1 ssh-ed25519 AAAA2\nm2 m2 ssh-ed25519 AAAA3'
}

run_issue() { PATH="$t/bin:$PATH" run bash -euo pipefail "$script" "$t/out"; }

@test "every token is minted with the one far validity, and no other" {
  run_issue
  [ "$status" -eq 0 ]
  [ "$(wc -l <"$t/calls")" -eq 5 ]
  [ "$(grep -c -- '--validity 100 years ' "$t/calls")" -eq 5 ]
}

@test "a read token pulls only; a write token pushes and pulls" {
  run_issue
  [ "$(grep -c -- '--validity 100 years --pull seedmatic$' "$t/calls")" -eq 3 ]
  [ "$(grep -c -- '--push seedmatic --pull seedmatic$' "$t/calls")" -eq 2 ]
  run grep -- '--sub m2 .*--push' "$t/calls"
  [ "$status" -eq 1 ]
}

@test "each machine gets this cache's netrc fragment; only this metalspace's get a write token" {
  run_issue
  [ -f "$t/out/m1/netrc.m1.age" ]
  [ -f "$t/out/m1/write.token.age" ]
  [ -f "$t/out/m1-nixos/netrc.m1.age" ]
  [ -f "$t/out/m1-nixos/write.token.age" ]
  [ -f "$t/out/m2/netrc.m1.age" ]
  [ ! -e "$t/out/m2/write.token.age" ]
  [ "$(cat "$t/out/m2/netrc.m1.age")" = $'machine attic.m1\npassword TOKEN-FOR-m2' ]
}

@test "the usage takes the out dir alone" {
  PATH="$t/bin:$PATH" run bash -euo pipefail "$script"
  [ "$status" -ne 0 ]
  [[ $output == *"usage: attic-token-issue <out dir>"* ]]
}

@test "no token reaches the output" {
  run_issue
  [[ $output != *TOKEN-FOR* ]]
}
