#!/usr/bin/env bats
# The fleet's KRL builder (keys-yaml.d/krl.sh) refuses, at build, a list that would cut more or less
# than keys.yaml says: a live certificate sharing a revoked key id, an id ssh-keygen would read as
# another, an authority slot it cannot find. revoked-host-keys.bats proves what a built list cuts.

UNION='{"marker":"ndh-ssh-key-meta-v1","owner":"home-manager.ssh-add-keys","key":"rdp-host","usage":["ssh-host"]}'

setup() {
  cd "$BATS_TEST_TMPDIR"
  for n in ca old-ca shared; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  ssh-keygen -q -s ca -h -I "$UNION" -z 0 -n localhost shared.pub && mv shared-cert.pub union-cert.pub
  ssh-keygen -q -s ca -h -I "${UNION/rdp-host/other}" -z 4 -n localhost shared.pub && mv shared-cert.pub other-cert.pub
  CA="$(cut -d' ' -f2 ca.pub)" OLDCA="$(cut -d' ' -f2 old-ca.pub)" UNION="$UNION" yq -n -o json '
    .authorities.fabric = {"type": "ssh-ed25519", "slots": {"26-01-01": {"public": strenv(CA)}}} |
    .keys = {} |
    .revoked."fabric@25-01-01" = {"type": "ssh-ed25519", "public": strenv(OLDCA), "reason": "retired"} |
    .revoked_certificates."rdp-host@26-01-01/0" = {"authority": "fabric", "authority_slot": "26-01-01", "key_id": strenv(UNION), "serial": 0}
  ' >base.json
}

build() { # <yq expression on base.json>
  UNION="$UNION" CERT="$(<union-cert.pub)" OTHER="$(<other-cert.pub)" yq -o json "$1" base.json >keys.json
  run bash "$KRL_SH" keys.json out.krl
}

@test "the list holds every revoked public and every revoked id, under its authority" {
  build '.'
  [ "$status" -eq 0 ]
  run ssh-keygen -Q -l -f out.krl
  [[ "$output" == *"# CA key ssh-ed25519 $(ssh-keygen -lf ca.pub | awk '{print $2}')"*"id: ${UNION}"* ]]
  run ssh-keygen -Q -f out.krl old-ca.pub
  [ "$status" -eq 1 ]
  run ssh-keygen -Q -f out.krl other-cert.pub
  [ "$status" -eq 0 ]
}

@test "a live recorded certificate with a revoked key id is refused, by name" {
  build '.keys."rdp-host".slots."26-01-01".certificates.fabric."ssh-host" = strenv(CERT)'
  [ "$status" -eq 1 ]
  [[ "$output" == *"rdp-host@26-01-01 fabric ssh-host: its recorded certificate has the key id revoked_certificates.rdp-host@26-01-01/0 revokes"* ]]
  [ ! -e out.krl ]
}

@test "a live recorded certificate with another key id passes" {
  build '.keys."rdp-host".slots."26-01-01".certificates.fabric."ssh-host" = strenv(OTHER)'
  [ "$status" -eq 0 ]
}

@test "an id ssh-keygen would read as another is refused: a '#', or edge spaces" {
  build '.revoked_certificates."rdp-host@26-01-01/0".key_id = "union#0"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"which ssh-keygen would read as another id"* ]]
  build '.revoked_certificates."rdp-host@26-01-01/0".key_id = "union "'
  [ "$status" -eq 1 ]
  [ ! -e out.krl ]
}

@test "an id is revoked under an authority slot already in revoked, from its public there" {
  build '.revoked_certificates."rdp-host@26-01-01/0".authority_slot = "25-01-01"'
  [ "$status" -eq 0 ]
  run ssh-keygen -Q -l -f out.krl
  [[ "$output" == *"# CA key ssh-ed25519 $(ssh-keygen -lf old-ca.pub | awk '{print $2}')"*"id: ${UNION}"* ]]
}

@test "an authority slot found nowhere is refused" {
  build '.revoked_certificates."rdp-host@26-01-01/0".authority_slot = "24-01-01"'
  [ "$status" -eq 1 ]
  [[ "$output" == *"no public for its authority fabric@24-01-01"* ]]
}
