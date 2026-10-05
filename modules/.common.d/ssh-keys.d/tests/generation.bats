#!/usr/bin/env bats
#
# The generation path: what the enrichment writes back into a slot when it finds
# one empty, and the shape of the artefacts it signs.
#
# These cases sign against a REAL throwaway ed25519 authority rather than a
# placeholder, because the defect they pin down was invisible to every check that
# did not rebuild the public-key line: `public` was written as a whole
# "<type> <blob> <comment>" line, so consumers that prepend the type and append
# the comment emitted both twice — and `ssh-keygen -lf` accepts that without a
# word.

load helper

# The generation the fixtures below carry. The accessors take the slot as a
# parameter rather than resolving the newest themselves, because the enrichment
# signs one generation at a time.
SLOT="26-10-04"

setup() {
  render_and_source "${BATS_TEST_DIRNAME}/../ssh-enrich-keys-yaml.sh"

  tmpdir="$(mktemp -d)"
  hostName="test-host"
  inventoryHostsCsv=""
  extraPrincipalsCsv=""

  # A real authority, so ssh-keygen actually signs and the cert is inspectable.
  ssh-keygen -q -t ed25519 -N "" -f "${tmpdir}/ca" -C "test-ca"
  authorityPrivate="$(<"${tmpdir}/ca")"
}

teardown() {
  rm -rf "$tmpdir"
}

# A key whose only slot is empty: this is how a renewal is requested.
empty_slot_fixture() {
  # Built into a variable first: `yq … | write_fixture` would run write_fixture in
  # a subshell, and the $inputFile it sets would not survive the pipe.
  local yaml
  yaml="$(AUTH_PRIV="$authorityPrivate" yq --null-input '
    {
      "authorities": { "test-ca": { "type": "ssh-ed25519", "slots": { "26-10-04": { "private": strenv(AUTH_PRIV) } } } },
      "keys": {
        "leaf": {
          "type": "ssh-ed25519",
          "authority": "test-ca",
          "comment": "leaf@test",
          "cert_usage": [ "ssh-user" ],
          "principals": { "nxmatic": "nxmatic" },
          "slots": { "26-10-04": {} }
        }
      }
    }')"
  write_fixture <<<"$yaml"
}

@test "an empty slot gets material, written into that slot" {
  empty_slot_fixture
  run sign::one_cert leaf "$SLOT" test-ca ssh-user
  [ "$status" -eq 0 ]

  run key::field leaf "$SLOT" public
  [ "$status" -eq 0 ]
  [ -n "$output" ]

  run key::field leaf "$SLOT" private
  [[ "$output" == *"PRIVATE KEY"* ]]
}

@test "the generated public is the BARE blob — no type prefix, no comment" {
  empty_slot_fixture
  sign::one_cert leaf "$SLOT" test-ca ssh-user >/dev/null

  local public
  public="$(key::field leaf "$SLOT" public)"

  # The three things a whole line would carry and a blob must not.
  [[ "$public" != ssh-* ]]
  [[ "$public" != *" "* ]]
  [[ "$public" != *"leaf@test"* ]]

  # And it IS a base64 blob of the declared type: ed25519 public blobs all
  # begin with the encoded "ssh-ed25519" type string.
  [[ "$public" == AAAAC3NzaC1lZDI1NTE5* ]]
}

@test "the line consumers rebuild from type+blob+comment is accepted by ssh-keygen" {
  empty_slot_fixture
  sign::one_cert leaf "$SLOT" test-ca ssh-user >/dev/null

  local type public comment
  type="$(yq -r '.keys.leaf.type' "$inputFile")"
  public="$(key::field leaf "$SLOT" public)"
  comment="$(yq -r '.keys.leaf.comment' "$inputFile")"

  printf '%s %s %s\n' "$type" "$public" "$comment" >"${tmpdir}/rebuilt.pub"
  run ssh-keygen -lf "${tmpdir}/rebuilt.pub"
  [ "$status" -eq 0 ]

  # ssh-keygen -lf is lenient enough to fingerprint a doubled line too, so the
  # assertion that actually discriminates is the field count.
  run awk '{ print NF }' "${tmpdir}/rebuilt.pub"
  [ "$output" = "3" ]
}

@test "the signed certificate certifies the key that was just generated" {
  empty_slot_fixture
  local cert
  cert="$(sign::one_cert leaf "$SLOT" test-ca ssh-user)"
  printf '%s\n' "$cert" >"${tmpdir}/leaf-cert.pub"

  local type public comment
  type="$(yq -r '.keys.leaf.type' "$inputFile")"
  public="$(key::field leaf "$SLOT" public)"
  comment="$(yq -r '.keys.leaf.comment' "$inputFile")"
  printf '%s %s %s\n' "$type" "$public" "$comment" >"${tmpdir}/leaf.pub"

  local keyFp certFp
  keyFp="$(ssh-keygen -lf "${tmpdir}/leaf.pub" | awk '{print $2}')"
  certFp="$(ssh-keygen -Lf "${tmpdir}/leaf-cert.pub" | awk '/Public key:/ {print $4; exit}')"
  [ -n "$keyFp" ]
  [ "$keyFp" = "$certFp" ]
}

@test "enrich::all_keys signs EVERY generation, and files the cert in its slot" {
  # Two generations published side by side: the state a renewal passes through.
  # Signing only the newest would leave the retiring key materialised on disk
  # with no certificate, which is half a renewal.
  local yaml
  yaml="$(AUTH_PRIV="$authorityPrivate" yq --null-input '
    {
      "authorities": { "test-ca": { "type": "ssh-ed25519", "slots": { "26-10-04": { "private": strenv(AUTH_PRIV) } } } },
      "keys": {
        "leaf": {
          "type": "ssh-ed25519",
          "authority": "test-ca",
          "comment": "leaf@test",
          "cert_usage": [ "ssh-user" ],
          "principals": { "nxmatic": "nxmatic" },
          "slots": { "26-07-12": {}, "26-10-04": {} }
        }
      }
    }')"
  write_fixture <<<"$yaml"

  run enrich::all_keys
  [ "$status" -eq 0 ]

  # A cert under each slot, and under the slot — not beside it.
  run yq -r '.keys.leaf.slots."26-07-12".certificates."test-ca"."ssh-user"' "$inputFile"
  [[ "$output" == ssh-ed25519-cert-v01@openssh.com* ]]
  run yq -r '.keys.leaf.slots."26-10-04".certificates."test-ca"."ssh-user"' "$inputFile"
  [[ "$output" == ssh-ed25519-cert-v01@openssh.com* ]]
  run yq -r '.keys.leaf | has("certificates")' "$inputFile"
  [ "$output" = "false" ]

  # And each certificate certifies ITS OWN generation — the two keys were
  # generated independently, so a shared tempfile would have crossed them.
  local slot
  for slot in 26-07-12 26-10-04; do
    yq -r ".keys.leaf.slots.\"${slot}\".certificates.\"test-ca\".\"ssh-user\"" "$inputFile" >"${tmpdir}/c.pub"
    printf 'ssh-ed25519 %s leaf@test\n' "$(key::field leaf "$slot" public)" >"${tmpdir}/k.pub"
    [ "$(ssh-keygen -lf "${tmpdir}/k.pub" | awk '{print $2}')" \
      = "$(ssh-keygen -Lf "${tmpdir}/c.pub" | awk '/Public key:/ {print $4; exit}')" ]
  done

  # The two generations must not be the same key.
  [ "$(key::field leaf 26-07-12 public)" != "$(key::field leaf 26-10-04 public)" ]
}

@test "a host certificate lists the extra principals verbatim, without variants" {
  empty_slot_fixture
  host_principals() {
    sign::one_cert leaf "$SLOT" test-ca ssh-host >"${tmpdir}/h-cert.pub"
    ssh-keygen -Lf "${tmpdir}/h-cert.pub" | awk '/Principals:/ {on=1; next} /Critical Options:/ {on=0} on {print $1}'
  }

  # The negative control: without extras, the guest's DNS name is not there, which
  # is exactly the state where a client rejects the certificate.
  run host_principals
  [ "$status" -eq 0 ]
  [[ "$output" != *"nixos.test-host"* ]]

  extraPrincipalsCsv="test-host-nixos,nixos.test-host"
  run host_principals
  [ "$status" -eq 0 ]
  grep -qx 'nixos.test-host' <<<"$output"
  grep -qx 'test-host-nixos' <<<"$output"
  # The variants are for host names; `nixos.test-host.lan` would name nothing.
  ! grep -q '^nixos\.test-host\.' <<<"$output"
  # And the names the variants DO apply to are still there.
  grep -qx 'test-host.lan' <<<"$output"
}

@test "a second cert_usage reuses the material generated by the first" {
  empty_slot_fixture
  sign::one_cert leaf "$SLOT" test-ca ssh-user >/dev/null
  local first
  first="$(key::field leaf "$SLOT" public)"

  sign::one_cert leaf "$SLOT" test-ca ssh-host >/dev/null
  local second
  second="$(key::field leaf "$SLOT" public)"

  [ "$first" = "$second" ]
}
