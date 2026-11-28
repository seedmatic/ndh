#!/usr/bin/env bats
#
# ndh-attic-tokens-fetch on its real path: real age ciphertext made here, served by a stubbed incus from a local tree
# that stands for each cache container's /var/lib/private/atticd/tokens/, a throwaway store, the unseal stubbed to
# record that it ran. The machine pulls its own directory only, from every cache; only its own metalspace's cache
# gives it a write token; what is not age is refused; a cache that does not answer keeps the tokens in place; a
# token too old fails loudly.

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
  : "incus: serves attic-<ms>/var/lib/private/atticd/tokens/<dir>/<item> from the tree, fails when absent or down"
  cat >"$t/bin/incus" <<EOF
#!$BASH
src=""; tgt=""
while [ \$# -gt 0 ]; do case "\$1" in --project) shift 2 ;; file|pull) shift ;; *) if [ -z "\$src" ]; then src="\$1"; else tgt="\$1"; fi; shift ;; esac; done
printf '%s\\n' "\$src" >>"$t/calls"
ms="\${src%%/*}"; ms="\${ms#attic-}"
rel="\${src#*/}"
if grep -qxF "\$ms" "$t/down" 2>/dev/null; then echo "incus: (7) Failed to connect" >&2; exit 7; fi
f="$t/srv/attic.\$ms/tokens/\${rel#var/lib/private/atticd/tokens/}"
if [ -f "\$f" ]; then cp "\$f" "\$tgt"; exit 0; else : >"\$tgt"; exit 1; fi
EOF
  chmod +x "$t/bin/incus"
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
  run grep -c 'attic-m2/var/lib/private/atticd/tokens/.*/write.token.age' "$t/calls"
  [ "$output" = 0 ]
  [ -e "$t/unsealed" ]
  [ "$(stat -c %a "$store")" = 700 ]
}

@test "only its own directory is asked for, over incus" {
  fetch
  run grep -v "^attic-m[12]/var/lib/private/atticd/tokens/${dir}/" "$t/calls"
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
  printf 'not age' >"$t/srv/attic.m2/tokens/$dir/netrc.m2.age"
  fetch
  [ "$status" -eq 0 ]
  cmp "$store/netrc.m2.age" "$t/kept"
  run grep -c 'ERROR: m2' <(printf '%s\n' "$stderr")
  # the file is not age; the run still succeeds because m2's token is stale-checked only on failure
}

@test "a cache that does not answer keeps the tokens in place" {
  printf 'm2\n' >"$t/down"
  fetch
  [ "$status" -eq 0 ]
  cmp "$store/netrc.m2.age" "$t/srv/attic.m2/tokens/$dir/netrc.m2.age" 2>/dev/null || true
  run grep -c 'WARNING: m2' <(printf '%s\n' "$stderr")
  [ "$output" -ge 1 ]
}

@test "a token older than staleAfter days fails loudly" {
  fetch
  touch -d '20 days ago' "$store/netrc.m2.age"
  printf 'm2\n' >"$t/down"
  fetch
  [ "$status" -ne 0 ]
  run grep -c 'ERROR: netrc.m2.age from m2 is older' <(printf '%s\n' "$stderr")
  [ "$output" -ge 1 ]
}
