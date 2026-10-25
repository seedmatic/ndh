#!/usr/bin/env bats
# ndh-attic-publish on throwaway keys: the guest reads what its cache container wrote on their shared disk device — the
# cache's public and its TLS key's CSR — as hostile input (a regular file, not a link, a bounded read into its own
# copy), checks that copy (a public named as the catalog accepts it; a CSR that verifies and names exactly the cache),
# and publishes it with a statement it signs with the key it serves (namespace seedmatic-attic), hashing the copy it
# checked; idempotent; nothing published from anything else.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  install -d -m 0755 "$t/var" "$t/shared"
  ssh-keygen -q -t ed25519 -N "" -C served -f "$t/served"
  good="seedmatic-m1-attic-1:$(head -c 32 /dev/urandom | base64 | tr -d '\n')"
  printf '%s\n' "$good" >"$t/shared/cache-key.public"
  openssl genpkey -algorithm EC -pkeyopt ec_paramgen_curve:P-256 -out "$t/tls.key" 2>/dev/null
  openssl req -new -key "$t/tls.key" -subj /CN=attic.m1 -addext subjectAltName=DNS:attic.m1 -out "$t/shared/request.csr"
  render
}

render() {
  # Rendered as replaceVars does (each value shell-quoted), through the real ndh trampoline and logger, run whole.
  : "${NDH_TRAMPOLINE:?the ndh bash trampoline}"
  local -A vars=(
    [nixBashTrampoline]="$NDH_TRAMPOLINE"
    [machine]=m1-nixos [cache]=m1 [fqdn]=attic.m1 [keyNameRegex]='seedmatic-m1-attic-[0-9]+'
    [sharedPublic]="$t/shared/cache-key.public" [sharedCsr]="$t/shared/request.csr" [openssl]="$(command -v openssl)"
    [base]="$t/var" [owner]="$(id -u)" [publishDir]="$t/var/attic/published" [hostKey]="$t/served"
  )
  local text k
  text="$(cat "$BATS_TEST_DIRNAME/../publish.sh")"
  for k in "${!vars[@]}"; do
    if [[ $k == nixBashTrampoline || $k == openssl ]]; then text="${text//@$k@/${vars[$k]}}"; else text="${text//@$k@/$(printf '%q' "${vars[$k]}")}"; fi
  done
  printf '%s\n' "$text" >"$t/publish"
  ! grep -q '@[a-zA-Z]*@' "$t/publish"
}

pub() { echo "$t/var/attic/published/attic-m1.cache-key.$1"; }

verify() { # the statement, against the key the guest serves, in namespace seedmatic-attic
  printf 'host-m1-nixos %s\n' "$(cut -d' ' -f1,2 "$t/served.pub")" >"$t/allowed"
  ssh-keygen -q -Y verify -f "$t/allowed" -I host-m1-nixos -n seedmatic-attic -s "$(pub statement.sig)" <"$(pub statement)"
}

nothing_published() { [ ! -e "$(pub public)" ] && [ ! -e "$(pub statement.sig)" ]; }

@test "the public is published with a statement the served key signed, naming the cache, the guest and its hash" {
  run --separate-stderr bash "$t/publish"
  [ "$status" -eq 0 ]
  [ "$(cat "$(pub public)")" = "$good" ]
  [ "$(cat "$(pub statement)")" = "$(printf 'seedmatic-attic v1\nclass attic-cache-key\ncache m1\nmachine m1-nixos\nsha256 %s' "$(sha256sum "$(pub public)" | cut -d' ' -f1)")" ]
  verify
  [ "$(stat -c %a "$t/var/attic/published")" = 755 ]
  [[ $stderr == *"m1 public published by m1-nixos: ${good}"* ]]
}

@test "the statement does not verify under another namespace" {
  bash "$t/publish"
  printf 'host-m1-nixos %s\n' "$(cut -d' ' -f1,2 "$t/served.pub")" >"$t/allowed"
  run ssh-keygen -q -Y verify -f "$t/allowed" -I host-m1-nixos -n seedmatic-rotate -s "$(pub statement.sig)" <"$(pub statement)"
  [ "$status" -ne 0 ]
}

@test "a second run publishes the same content, still verified" {
  bash "$t/publish"
  first="$(cat "$(pub public)" "$(pub statement)")"
  bash "$t/publish"
  [ "$(cat "$(pub public)" "$(pub statement)")" = "$first" ]
  verify
}

@test "no public written yet: nothing to publish, not a failure" {
  rm -f "$t/shared/cache-key.public"
  run --separate-stderr bash "$t/publish"
  [ "$status" -eq 0 ]
  [[ $stderr == *"has not written its public yet"* ]]
  nothing_published
}

csr() { echo "$t/var/attic/published/attic-m1.tls-csr.$1"; }

@test "the CSR is published with its statement, signed by the served key, class attic-tls-csr" {
  run --separate-stderr bash "$t/publish"
  [ "$status" -eq 0 ]
  openssl req -in "$(csr csr)" -noout -verify 2>/dev/null
  [ "$(openssl req -in "$(csr csr)" -noout -pubkey)" = "$(openssl pkey -in "$t/tls.key" -pubout)" ]
  [ "$(cat "$(csr statement)")" = "$(printf 'seedmatic-attic v1\nclass attic-tls-csr\ncache m1\nmachine m1-nixos\nsha256 %s' "$(sha256sum "$(csr csr)" | cut -d' ' -f1)")" ]
  printf 'host-m1-nixos %s\n' "$(cut -d' ' -f1,2 "$t/served.pub")" >"$t/allowed"
  ssh-keygen -q -Y verify -f "$t/allowed" -I host-m1-nixos -n seedmatic-attic -s "$(csr statement.sig)" <"$(csr statement)"
  [[ $stderr == *"m1 TLS CSR published by m1-nixos: CN=attic.m1"* ]]
}

@test "mutant: a CSR for another name, or that does not verify, is refused" {
  openssl req -new -key "$t/tls.key" -subj /CN=attic.m2 -addext subjectAltName=DNS:attic.m2 -out "$t/shared/request.csr"
  run --separate-stderr bash "$t/publish"
  [ "$status" -ne 0 ]
  [[ $stderr == *"subject is not CN=attic.m1"* ]]
  [ ! -e "$(csr csr)" ]
  printf 'not a csr\n' >"$t/shared/request.csr"
  run --separate-stderr bash "$t/publish"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not one CSR that verifies"* ]]
  [ ! -e "$(csr csr)" ]
}

@test "mutant: a CSR that is a symlink is refused" {
  cp "$t/shared/request.csr" "$t/elsewhere.csr"
  rm -f "$t/shared/request.csr"
  ln -s "$t/elsewhere.csr" "$t/shared/request.csr"
  run --separate-stderr bash "$t/publish"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a regular file (a symlink?)"* ]]
  [ ! -e "$(csr csr)" ]
}

@test "the CSR's private key is never published nor printed" {
  run --separate-stderr bash "$t/publish"
  ! grep -rq 'PRIVATE KEY' "$t/var/attic/published" || false
  [[ $output$stderr != *"PRIVATE KEY"* ]]
}

@test "mutant: a shared file that is a symlink is refused, its target never read" {
  printf '%s\n' "$good" >"$t/elsewhere"
  rm -f "$t/shared/cache-key.public"
  ln -s "$t/elsewhere" "$t/shared/cache-key.public"
  run --separate-stderr bash "$t/publish"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a regular file (a symlink?)"* ]]
  nothing_published
}

@test "mutant: a public of another metalspace, a bare name, or two lines is refused" {
  for bad in "seedmatic-m2-attic-1:${good#*:}" "seedmatic:${good#*:}" "$(printf '%s\n%s' "$good" "$good")" "${good}x"; do
    printf '%s\n' "$bad" >"$t/shared/cache-key.public"
    run --separate-stderr bash "$t/publish"
    [ "$status" -ne 0 ]
    [[ $stderr == *"is not one m1 public key named as the catalog accepts it"* ]]
    nothing_published
  done
}

@test "mutant: an oversized shared file is read bounded, then refused" {
  { printf '%s' "$good"; head -c 1048576 /dev/zero | tr '\0' A; } >"$t/shared/cache-key.public"
  run --separate-stderr bash "$t/publish"
  [ "$status" -ne 0 ]
  nothing_published
}

@test "mutant: the shared file swapped after the read changes nothing signed — the copy is what is hashed" {
  : "a writer racing the guest: the shared file changes right after the bounded read (injected into a test copy)"
  sed -i 's|^    public="\$(<"\$work/public.read")"$|    printf "seedmatic-m1-attic-9:%s\\n" "${good#*:}" >"$sharedPublic"\n&|' "$t/publish"
  sed -i "s|^readonly machine=|good=$(printf '%q' "$good")\n&|" "$t/publish"
  grep -q 'seedmatic-m1-attic-9' "$t/publish"
  bash "$t/publish"
  [ "$(cat "$(pub public)")" = "$good" ]
  verify
  grep -q "sha256 $(printf '%s\n' "$good" | sha256sum | cut -d' ' -f1)" "$(pub statement)"
}

@test "a published directory that is a symlink is refused" {
  mkdir -p "$t/elsewhere-dir" "$t/var/attic"
  ln -s "$t/elsewhere-dir" "$t/var/attic/published"
  run --separate-stderr bash "$t/publish"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is not a directory (a symlink?)"* ]]
  [ -z "$(ls -A "$t/elsewhere-dir")" ]
}

@test "a group- or world-writable directory on the way is refused" {
  install -d -m 0777 "$t/var/attic"
  run --separate-stderr bash "$t/publish"
  [ "$status" -ne 0 ]
  [[ $stderr == *"is group- or world-writable"* ]]
  nothing_published
}

@test "no private is ever printed" {
  run --separate-stderr bash "$t/publish"
  [[ $output$stderr != *"PRIVATE KEY"* ]]
  [[ $output$stderr != *"$(sed -n 2p "$t/served")"* ]]
}
