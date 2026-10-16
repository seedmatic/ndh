#!/usr/bin/env bats
# A machine owning its host key (ndh.hostKey.own) has sshd generate none, so a key not yet placed must
# stop a REAL sshd outright, never leave it serving something else.

setup() {
  cd "$BATS_TEST_TMPDIR"
  ssh-keygen -q -t ed25519 -N '' -f present -C present
  port=$((20000 + RANDOM % 20000))
}

teardown() {
  [ -f sshd.pid ] && kill "$(cat sshd.pid)" 2>/dev/null || true
}

# $1 the HostKey path.
start() {
  cat >sshd_config <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $1
StrictModes no
PidFile $PWD/sshd.pid
EOF
  run "$(command -v sshd)" -f "$PWD/sshd_config" -E "$PWD/sshd.log"
  for _ in 1 2 3 4 5; do [ -s sshd.pid ] && break; sleep 0.2; done
  printf 'sshd: %s\n--- sshd.log\n%s\n' "$output" "$(cat sshd.log 2>/dev/null)"
}

@test "an sshd whose only HostKey is missing refuses to start" {
  start "$PWD/absent"
  [ "$status" -ne 0 ]
  [ ! -s sshd.pid ]
  grep -q "no hostkeys available" sshd.log
}

@test "the same sshd starts once the key is placed" {
  start "$PWD/present"
  [ "$status" -eq 0 ]
  [ -s sshd.pid ]
}
