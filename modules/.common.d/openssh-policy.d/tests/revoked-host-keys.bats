#!/usr/bin/env bats
# RevokedHostKeys, the client-side twin of sshd's RevokedKeys, against a REAL sshd on loopback: a host
# certificate is valid forever by decision, so revocation is what must cut a leaked host key, or one
# certificate of a key that stays valid (the union host certificate, roles × keys S3a). Every list is
# the KRL keys-yaml.d/krl.sh builds, from an extraction shaped as keys-yaml.nix writes it. What is
# asserted is the HOST authentication (`ssh -v`: "Authenticated to" or "revoked"), not the session: a
# build user's shell may be nologin.

UNION='{"marker":"ndh-ssh-key-meta-v1","owner":"home-manager.ssh-add-keys","key":"rdp-host","usage":["ssh-host"]}'
OWN='{"marker":"ndh-ssh-key-meta-v1","key":"rdp-host","names":"beta","issued":"2026-10-16T00:00:00Z"}'

setup() {
  cd "$BATS_TEST_TMPDIR"
  for n in host ca leaked user; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  ssh-keygen -q -s ca -h -I host -n localhost host.pub
  ssh-keygen -q -s ca -h -I leaked -n localhost leaked.pub
  # Two certificates of ONE key, the union one (serial 0, as signed before S3a) and its successor.
  cp host.pub shared.pub
  cp host shared
  ssh-keygen -q -s ca -h -I "$UNION" -z 0 -n localhost shared.pub && mv shared-cert.pub union-cert.pub
  ssh-keygen -q -s ca -h -I "$OWN" -z 3 -n localhost shared.pub && mv shared-cert.pub own-cert.pub
  CA="$(cut -d' ' -f2 ca.pub)" yq -n -o json '.authorities.fabric = {"type": "ssh-ed25519", "slots": {"26-01-01": {"public": strenv(CA)}}} | .keys = {} | .revoked = {} | .revoked_certificates = {}' >base.json
  krl revoked-none.krl '.'
  krl revoked-leaked.krl '.revoked."leaked@26-01-01" = {"type": "ssh-ed25519", "public": strenv(LEAKED), "reason": "leaked"}'
  krl revoked-ca.krl '.revoked."fabric@26-01-01" = {"type": "ssh-ed25519", "public": strenv(CA), "reason": "leaked"}'
  krl revoked-union.krl '.revoked_certificates."rdp-host@26-01-01/0" = {"authority": "fabric", "authority_slot": "26-01-01", "key_id": strenv(UNION), "serial": 0}'
  cp user.pub authorized_keys
  echo "@cert-authority localhost $(cut -d' ' -f1-2 ca.pub)" >known-ca
  echo "localhost $(cut -d' ' -f1-2 leaked.pub)" >known-leaked
  port=$((20000 + RANDOM % 20000))
  # The nix sandbox's passwd gives the build user the shell /noshell, which does not exist, and sshd
  # refuses such a user before any key. sshd alone reads this one, naming a shell that does.
  printf '%s:x:%s:%s::%s:%s\n' "$(id -un)" "$(id -u)" "$(id -g)" "$PWD" "$(command -v bash)" >passwd
  printf '%s:x:%s:\n' "$(id -gn)" "$(id -g)" >group
}

# The KRL of base.json changed by a yq expression, through the builder the evaluation runs.
krl() { # <out> <yq expression>
  CA="$(cut -d' ' -f2 ca.pub)" LEAKED="$(cut -d' ' -f2 leaked.pub)" UNION="$UNION" yq -o json "$2" base.json >"$1.json"
  bash "$KRL_SH" "$1.json" "$1"
}

teardown() {
  [ -f sshd.pid ] && kill "$(cat sshd.pid)" 2>/dev/null || true
}

# $1 host key, $2 host certificate or "", then: connect with $3 revocation list and $4 known hosts.
connect() {
  cat >sshd_config <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $PWD/$1
${2:+HostCertificate $PWD/$2}
AuthorizedKeysFile $PWD/authorized_keys
StrictModes no
PidFile $PWD/sshd.pid
EOF
  LD_PRELOAD="$NSS_WRAPPER_LIB" NSS_WRAPPER_PASSWD="$PWD/passwd" NSS_WRAPPER_GROUP="$PWD/group" \
    "$(command -v sshd)" -f "$PWD/sshd_config" -E "$PWD/sshd.log"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s sshd.pid ] && break; sleep 0.2; done
  run ssh -v -F /dev/null -p "$port" -i user -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=yes -o UserKnownHostsFile="$PWD/$4" -o GlobalKnownHostsFile=/dev/null \
    -o RevokedHostKeys="$PWD/$3" localhost true
  # Shown by bats only when a case fails: what the client said, and why sshd may not have started.
  printf 'ssh: %s\n--- sshd.log\n%s\n' "$output" "$(cat sshd.log 2>/dev/null)"
  if [ -s sshd.pid ]; then kill "$(cat sshd.pid)" || true; fi
  rm -f sshd.pid
}

@test "a healthy host certificate from the trusted authority is accepted" {
  connect host host-cert.pub revoked-none.krl known-ca
  [[ "$output" == *"Authenticated to localhost"* ]]
}

@test "a revoked host KEY behind a valid certificate is refused, through the KRL" {
  connect leaked leaked-cert.pub revoked-leaked.krl known-ca
  [ "$status" -eq 255 ]
  [[ "$output" == *"revoked"* ]]
  [[ "$output" != *"Authenticated to"* ]]
}

@test "a certificate signed by a revoked authority is refused" {
  connect host host-cert.pub revoked-ca.krl known-ca
  [ "$status" -eq 255 ]
  [[ "$output" == *"revoked"* ]]
  [[ "$output" != *"Authenticated to"* ]]
}

@test "a revoked host key is refused even where it is pinned" {
  connect leaked "" revoked-leaked.krl known-leaked
  [ "$status" -eq 255 ]
  [[ "$output" == *"revoked"* ]]
  [[ "$output" != *"Authenticated to"* ]]
}

@test "an empty revocation list refuses nothing" {
  connect leaked leaked-cert.pub revoked-none.krl known-ca
  [[ "$output" == *"Authenticated to localhost"* ]]
}

@test "a certificate revoked by its key id is refused" {
  connect shared union-cert.pub revoked-union.krl known-ca
  [ "$status" -eq 255 ]
  [[ "$output" == *"revoked"* ]]
  [[ "$output" != *"Authenticated to"* ]]
}

@test "another certificate of the same key, with another id, is accepted under the same list" {
  connect shared own-cert.pub revoked-union.krl known-ca
  [[ "$output" == *"Authenticated to localhost"* ]]
}
