#!/usr/bin/env bats
# ndh-root-attest with a throwaway P-384 root: a statement verifies only for the authority, usage and key it names,
# only before its not-after, only under the root's signature in the seedmatic-attest namespace.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${ATTEST:?the ndh-root-attest binary}"
  ssh-keygen -q -t ecdsa -b 384 -N "" -C root -f "$t/root"
  ssh-keygen -q -t ed25519 -N "" -C ca -f "$t/ca"
  ssh-keygen -q -t ed25519 -N "" -C other -f "$t/other"
  root="$(cut -d' ' -f1,2 "$t/root.pub")"
  ca="$(cut -d' ' -f1,2 "$t/ca.pub")"
  other="$(cut -d' ' -f1,2 "$t/other.pub")"
  "$ATTEST" statement --name fabric-ssh-host --usage ssh-host --key "$ca" --not-after 2028-10-18 >"$t/st"
  ssh-keygen -q -Y sign -f "$t/root" -n seedmatic-attest "$t/st"
}

verify() { # [overrides…]
  "$ATTEST" verify --root "$root" --statement "$t/st" --signature "$t/st.sig" \
    --name fabric-ssh-host --usage ssh-host --key "$ca" --today 2026-10-18 "$@"
}

@test "the statement is canonical, and the root's signature over it verifies for that authority" {
  [ "$(sed -n 1p "$t/st")" = "seedmatic-attest v1" ]
  [ "$(wc -l <"$t/st")" -eq 5 ]
  run --separate-stderr verify
  [ "$status" -eq 0 ]
  [ "$output" = "ok fabric-ssh-host ssh-host until 2028-10-18" ]
}

@test "another usage, another name or another key is refused: a statement cannot be replayed" {
  run --separate-stderr verify --usage ssh-user
  [ "$status" -eq 1 ]
  run --separate-stderr verify --name fabric-ssh-user
  [ "$status" -eq 1 ]
  run --separate-stderr verify --key "$other"
  [ "$status" -eq 1 ]
  [[ $stderr == *"does not attest"* ]]
}

@test "an attestation past its not-after is refused" {
  run --separate-stderr verify --today 2028-10-19
  [ "$status" -eq 1 ]
  [[ $stderr == *"expired on 2028-10-18"* ]]
  run --separate-stderr verify --today 2028-10-18
  [ "$status" -eq 0 ]
}

@test "a statement changed after signing is refused" {
  sed -i 's/^not-after .*/not-after 2099-01-01/' "$t/st"
  run --separate-stderr verify
  [ "$status" -eq 1 ]
  [[ $stderr == *"not the root's"* ]]
}

@test "a signature in another namespace, or by another key, is refused" {
  rm "$t/st.sig"
  ssh-keygen -q -Y sign -f "$t/root" -n file "$t/st"
  run --separate-stderr verify
  [ "$status" -eq 1 ]
  ssh-keygen -q -t ecdsa -b 384 -N "" -C impostor -f "$t/impostor"
  rm "$t/st.sig"
  ssh-keygen -q -Y sign -f "$t/impostor" -n seedmatic-attest "$t/st"
  run --separate-stderr verify
  [ "$status" -eq 1 ]
}

@test "a root that is not P-384 is refused" {
  run --separate-stderr "$ATTEST" verify --root "$other" --statement "$t/st" --signature "$t/st.sig" \
    --name fabric-ssh-host --usage ssh-host --key "$ca" --today 2026-10-18
  [ "$status" -eq 1 ]
  [[ $stderr == *"P-384"* ]]
}

@test "malformed inputs are refused before anything is written" {
  run --separate-stderr "$ATTEST" statement --name fabric-ssh-host --usage everything --key "$ca" --not-after 2028-10-18
  [ "$status" -eq 1 ]
  run --separate-stderr "$ATTEST" statement --name fabric-ssh-host --usage ssh-host --key "$ca" --not-after 2028-02-30
  [ "$status" -eq 1 ]
  run --separate-stderr "$ATTEST" statement --name fabric-ssh-host --usage ssh-host --key "not a key" --not-after 2028-10-18
  [ "$status" -eq 1 ]
  run --separate-stderr "$ATTEST" statement --name Fabric --usage ssh-host --key "$ca" --not-after 2028-10-18
  [ "$status" -eq 1 ]
  [ -z "$output" ]
}
