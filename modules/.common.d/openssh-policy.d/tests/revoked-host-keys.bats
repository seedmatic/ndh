#!/usr/bin/env bats
# RevokedHostKeys, the client-side twin of sshd's RevokedKeys, against a REAL sshd on loopback: a host
# certificate is valid forever by decision, so revocation is what must cut a leaked host key. The
# revoked file has the shape keys-yaml.nix writes (`<type> <blob> revoked:<id>`), which ssh-keygen -Q
# cannot read (it wants a KRL) — hence a connection, not a query. What is asserted is the HOST
# authentication (`ssh -v`: "Authenticated to" or "revoked"), not the session: a build user's shell
# may be nologin.

setup() {
  cd "$BATS_TEST_TMPDIR"
  for n in host ca leaked user; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  ssh-keygen -q -s ca -h -I host -n localhost host.pub
  ssh-keygen -q -s ca -h -I leaked -n localhost leaked.pub
  revoked() { for k in "$@"; do awk -v id="$k" '{print $1" "$2" revoked:"id}' "$k.pub"; done; }
  revoked leaked >revoked-leaked.pub
  revoked ca >revoked-ca.pub
  : >revoked-none.pub
  cp user.pub authorized_keys
  echo "@cert-authority localhost $(cut -d' ' -f1-2 ca.pub)" >known-ca
  echo "localhost $(cut -d' ' -f1-2 leaked.pub)" >known-leaked
  port=$((20000 + RANDOM % 20000))
}

teardown() {
  [ -f sshd.pid ] && kill "$(cat sshd.pid)" 2>/dev/null || true
}

# $1 host key, $2 host certificate or "", then: connect with $3 revoked file and $4 known hosts.
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
  connect host host-cert.pub revoked-none.pub known-ca
  [[ "$output" == *"Authenticated to localhost"* ]]
}

@test "a revoked host KEY behind a valid certificate is refused" {
  connect leaked leaked-cert.pub revoked-leaked.pub known-ca
  [ "$status" -eq 255 ]
  [[ "$output" == *"revoked"* ]]
  [[ "$output" != *"Authenticated to"* ]]
}

@test "a certificate signed by a revoked authority is refused" {
  connect host host-cert.pub revoked-ca.pub known-ca
  [ "$status" -eq 255 ]
  [[ "$output" == *"revoked"* ]]
  [[ "$output" != *"Authenticated to"* ]]
}

@test "a revoked host key is refused even where it is pinned" {
  connect leaked "" revoked-leaked.pub known-leaked
  [ "$status" -eq 255 ]
  [[ "$output" == *"revoked"* ]]
  [[ "$output" != *"Authenticated to"* ]]
}

@test "an empty revoked list refuses nothing" {
  connect leaked leaked-cert.pub revoked-none.pub known-ca
  [[ "$output" == *"Authenticated to localhost"* ]]
}
