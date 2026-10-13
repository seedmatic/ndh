#!/usr/bin/env bats
#
# The install path (roles × keys 6a): every SSH certificate is signed ON THE SEAT and recorded in
# keys.yaml, and the activation installs it as recorded — it signs nothing and generates nothing for
# an SSH key, so it needs no SSH authority private. A missing certificate or missing material is a
# hard error, never something filled in here.

load helper

setup() {
  render_and_source "${BATS_TEST_DIRNAME}/../ssh-enrich-keys-yaml.sh"
  tmpdir="${BATS_TEST_TMPDIR}/work"
  mkdir -p "$tmpdir"
}

# Roles × keys 6a: a generation whose public is recorded is certified ON THE SEAT. The activation
# installs that certificate as recorded and signs nothing for it — so it needs no authority private.
recorded_fixture() { # <with certificate: yes|no>
  ssh-keygen -q -t ed25519 -N '' -f "${tmpdir}/recorded" -C recorded
  ssh-keygen -q -t ed25519 -N '' -f "${tmpdir}/seat-ca" -C seat-ca
  ssh-keygen -q -s "${tmpdir}/seat-ca" -h -I seat -n bioskop "${tmpdir}/recorded.pub"
  local cert=""
  [ "$1" = yes ] && cert="$(<"${tmpdir}/recorded-cert.pub")"
  write_fixture <<<"$(PUB="$(cut -d' ' -f2 "${tmpdir}/recorded.pub")" CERT="$cert" yq --null-input '
    {
      "authorities": { "test-ca": { "type": "ssh-ed25519", "slots": { "26-10-04": { "public": "unused" } } } },
      "keys": {
        "host": {
          "type": "ssh-ed25519",
          "authority": "test-ca",
          "cert_usage": [ "ssh-host" ],
          "slots": { "26-10-04": { "public": strenv(PUB), "private": "recorded-private" } }
        }
      }
    } | with(select(strenv(CERT) != ""); .keys.host.slots."26-10-04".certificates."test-ca"."ssh-host" = strenv(CERT))')"
}

@test "a recorded certificate is installed as recorded, with no authority private on the host" {
  recorded_fixture yes
  local before
  before="$(yq -r '.keys.host.slots."26-10-04".certificates."test-ca"."ssh-host"' "$inputFile")"
  run enrich::all_keys
  [ "$status" -eq 0 ]
  [ "$(yq -r '.keys.host.slots."26-10-04".certificates."test-ca"."ssh-host"' "$inputFile")" = "$before" ]
}

@test "a recorded public without its recorded certificate stops the enrichment" {
  recorded_fixture no
  run enrich::all_keys
  [ "$status" -eq 1 ]
  [[ "$output" == *"its public is recorded but its certificate is not"*"ssh-keys-certify"* ]]
}

@test "an SSH slot with no recorded material stops the enrichment — nothing is generated here" {
  write_fixture <<<"$(yq --null-input '
    {
      "authorities": { "test-ca": { "type": "ssh-ed25519", "slots": { "26-10-04": { "public": "unused" } } } },
      "keys": {
        "host": { "type": "ssh-ed25519", "authority": "test-ca", "cert_usage": [ "ssh-user" ], "slots": { "26-10-04": {} } }
      }
    }')"
  run enrich::all_keys
  [ "$status" -eq 1 ]
  [[ "$output" == *"no recorded material"*"ssh-keys-renew"*"ssh-keys-certify"* ]]
  [ "$(yq -r '.keys.host.slots."26-10-04".public // "none"' "$inputFile")" = none ]
}
