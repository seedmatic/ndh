#!/usr/bin/env bats
#
# ndh-attic-tokens-fetch on its real path: real age ciphertext made here, served by a stubbed curl from a local tree
# that stands for each cache's /tokens/, a throwaway store, the unseal stubbed to record that it ran. The machine pulls
# its own directory only, from every cache; only its own metalspace's cache gives it a write token; what is not age
# is refused; a cache that does not answer keeps the tokens in place; a token too old fails loudly.

bats_require_minimum_version 1.5.0

setup() {
  t=$BATS_TEST_TMPDIR
  store=$t/store
  dir=$(printf 'd%.0s' {1..64})
  age-keygen -o "$t/identity" 2>/dev/null
  r="$(age-keygen -y "$t/identity")"
  : "the two caches' served trees"
  for ms in m1 m2; do
    mkdir -p "$t/srv/attic.$ms/tokens/$dir"
    printf 'machine attic.%s\npassword a.b.c\n' "$ms" | age -r "$r" -o "$t/srv/attic.$ms/tokens/$dir/netrc.$ms.age"
  done
  printf 'w.x.y' | age -r "$r" -o "$t/srv/attic.m1/tokens/$dir/write.token.age"
  mkdir -p "$t/bin"
  : "curl: serves http://<fqdn>/<path> from the tree, 404 when absent; refuses a cache listed in down"
  cat >"$t/bin/curl" <<EOF
#!$BASH
url="\${@: -1}"
while [ \$# -gt 0 ]; do case "\$1" in -o) out="\$2"; shift 2 ;; *) shift ;; esac; done
printf '%s\n' "\$url" >>"$t/calls"
host="\${url#http://}"; host="\${host%%/*}"
if grep -qxF "\$host" "$t/down" 2>/dev/null; then echo "curl: (7) Failed to connect" >&2; exit 7; fi
f="$t/srv/\${url#http://}"
if [ -f "\$f" ]; then cp "\$f" "\$out"; printf 200; else : >"\$out"; printf 404; fi
EOF
  chmod +x "$t/bin/curl"
  printf '#!%s\ntouch %q\n' "$BASH" "$t/unsealed" >"$t/unseal" && chmod +x "$t/unseal"
  render "$dir"
}

render() { # <dir>
  {
    printf 'set -euo pipefail\nexport PATH=%q:$PATH\n' "$t/bin"
    printf 'machine=m1-nixos own=m1 store=%q dir=%q maxBytes=65536 staleAfter=10 unseal=%q\n' "$store" "$1" "$t/unseal"
    printf 'declare -A caches=([m1]=attic.m1 [m2]=attic.m2)\n'
    cat "$BATS_TEST_DIRNAME/../fetch.sh"
  } >"$t/fetch"
}

fetch() { run --separate-stderr bash "$t/fetch"; }

@test "the machine pulls its own tokens from every cache; a write token from its own metalspace's only" {
  fetch
  [ "$status" -eq 0 ]
  cmp "$store/netrc.m1.age" "$t/srv/attic.m1/tokens/$dir/netrc.m1.age"
  cmp "$store/netrc.m2.age" "$t/srv/attic.m2/tokens/$dir/netrc.m2.age"
  cmp "$store/write.token.age" "$t/srv/attic.m1/tokens/$dir/write.token.age"
  run grep -c 'attic.m2/tokens/.*/write.token.age' "$t/calls"
  [ "$output" = 0 ]
  [ -e "$t/unsealed" ]
  [ "$(stat -c %a "$store")" = 700 ]
}

@test "only its own directory is asked for, over http" {
  fetch
  run grep -v "^http://attic\.m[12]/tokens/${dir}/" "$t/calls"
  [ -z "$output" ]
}

@test "a new generation keeps the previous one as .prev" {
  fetch
  cp "$store/netrc.m1.age" "$t/first"
  printf 'machine attic.m1\npassword d.e.f\n' | age -r "$(age-keygen -y "$t/identity")" -o "$t/srv/attic.m1/tokens/$dir/netrc.m1.age"
  fetch
  [ "$status" -eq 0 ]
  cmp "$store/netrc.m1.age.prev" "$t/first"
  cmp "$store/netrc.m1.age" "$t/srv/attic.m1/tokens/$dir/netrc.m1.age"
}

@test "a served file that is not age is refused and the token in place kept" {
  fetch
  cp "$store/netrc.m2.age" "$t/kept"
  printf 'machine attic.m2\npassword IN.CLEAR.TOKEN\n' >"$t/srv/attic.m2/tokens/$dir/netrc.m2.age"
  fetch
  [[ $stderr == *"is not age ciphertext: refused"* ]]
  cmp "$store/netrc.m2.age" "$t/kept"
  run grep -rq IN.CLEAR.TOKEN "$store"
  [ "$status" -eq 1 ]
}

@test "a cache that does not answer keeps the tokens in place, and is no failure while they are fresh" {
  fetch
  cp "$store/netrc.m2.age" "$t/kept"
  echo attic.m2 >"$t/down"
  fetch
  [ "$status" -eq 0 ]
  [[ $stderr == *"attic.m2 did not answer"* ]]
  cmp "$store/netrc.m2.age" "$t/kept"
}

@test "a token older than one and a half periods fails the run loudly" {
  fetch
  echo attic.m2 >"$t/down"
  touch -d '11 days ago' "$store/netrc.m2.age"
  fetch
  [ "$status" -eq 1 ]
  [[ $stderr == *"netrc.m2.age from attic.m2 is older than 10 days"* ]]
}

@test "a cache never reached fails the run loudly" {
  echo attic.m2 >"$t/down"
  fetch
  [ "$status" -eq 1 ]
  [[ $stderr == *"or was never fetched"* ]]
}

@test "a directory that is not a sha256 is refused before anything is asked" {
  render "../etc"
  fetch
  [ "$status" -eq 1 ]
  [[ $stderr == *"is not a sha256"* ]]
  [ ! -e "$t/calls" ]
}
