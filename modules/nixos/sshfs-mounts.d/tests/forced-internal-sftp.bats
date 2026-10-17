#!/usr/bin/env bats
#
# What deploys: a REAL sshd on loopback authorizing a test key by an authorized_keys line carrying the seat's
# own options, AUTHORIZED_OPTIONS (ndh.sshfs.authorizedOptions, `restrict,command="internal-sftp -R"`), and
# a real `sftp -b` as that key. The control line forces `internal-sftp` without -R, where a write succeeds:
# a refusal that would happen anyway proves nothing about -R.

bats_require_minimum_version 1.5.0

setup() {
  : "${AUTHORIZED_OPTIONS:?the authorized_keys options of the seat}" "${NSS_WRAPPER_LIB:?}"
  cd "$BATS_TEST_TMPDIR"
  for n in host user; do ssh-keygen -q -t ed25519 -N '' -f "$n" -C "$n"; done
  mkdir -p store/repo.git/hooks
  printf 'ref: refs/heads/develop\n' >store/repo.git/HEAD
  printf 'payload\n' >upload
  port=$((20000 + RANDOM % 20000))
  # The nix sandbox's passwd gives the build user the shell /noshell, which does not exist, and sshd
  # refuses such a user before any key. sshd alone reads this one, naming the bats bash: the darwin
  # sandbox refuses /usr/bin/env, and a forced internal-sftp never runs the shell anyway.
  printf '%s:x:%s:%s::%s:%s\n' "$(id -un)" "$(id -u)" "$(id -g)" "$PWD" "$BASH" >passwd
  printf '%s:x:%s:\n' "$(id -gn)" "$(id -g)" >group
}

teardown() {
  [ -f sshd.pid ] && kill "$(cat sshd.pid)" 2>/dev/null || true
}

# $1 the authorized_keys options; starts sshd with exactly that line for user.pub.
serve() {
  printf '%s %s\n' "$1" "$(<user.pub)" >authorized_keys
  # The operator seat's own Subsystem line (modules/darwin/openssh.nix): sshd applies a forced command to
  # a subsystem request only once the subsystem exists.
  cat >sshd_config <<EOF
Port $port
ListenAddress 127.0.0.1
HostKey $PWD/host
AuthorizedKeysFile $PWD/authorized_keys
StrictModes no
PidFile $PWD/sshd.pid
Subsystem sftp internal-sftp
EOF
  LD_PRELOAD="$NSS_WRAPPER_LIB" NSS_WRAPPER_PASSWD="$PWD/passwd" NSS_WRAPPER_GROUP="$PWD/group" \
    "$(command -v sshd)" -f "$PWD/sshd_config" -E "$PWD/sshd.log"
  for _ in 1 2 3 4 5 6 7 8 9 10; do [ -s sshd.pid ] && break; sleep 0.2; done
}

# One batch command as user, so a refused write fails the run. Shown by bats only when a case fails.
sftp_as_user() {
  printf '%s\n' "$1" >batch
  run sftp -q -b batch -F /dev/null -P "$port" -i user -o IdentitiesOnly=yes -o BatchMode=yes \
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null localhost
  printf 'sftp: %s\n--- sshd.log\n%s\n' "$output" "$(cat sshd.log 2>/dev/null)"
}
unchanged() {
  [ "$(<store/repo.git/HEAD)" = "ref: refs/heads/develop" ] && [ -z "$(ls store/repo.git/hooks)" ] &&
    [ "$(find store | sort | tr '\n' ' ')" = "store store/repo.git store/repo.git/HEAD store/repo.git/hooks " ]
}

@test "the seat's options are restrict and a forced internal-sftp -R, exactly" {
  [ "$AUTHORIZED_OPTIONS" = 'restrict,command="internal-sftp -R"' ]
}

@test "through sshd with the seat's line: a get works" {
  serve "$AUTHORIZED_OPTIONS"
  sftp_as_user "get $PWD/store/repo.git/HEAD $PWD/got"
  [ "$status" -eq 0 ]
  [ "$(<got)" = "ref: refs/heads/develop" ]
  unchanged
}

@test "through sshd with the seat's line: put, rm, mkdir and rename are refused" {
  serve "$AUTHORIZED_OPTIONS"
  for op in "put $PWD/upload $PWD/store/repo.git/hooks/post-checkout" "rm $PWD/store/repo.git/HEAD" \
    "mkdir $PWD/store/repo.git/refs" "rename $PWD/store/repo.git/HEAD $PWD/store/repo.git/ORIG"; do
    sftp_as_user "$op"
    [ "$status" -ne 0 ]
    unchanged
  done
}

@test "through sshd with the seat's line: no shell, the forced command answers instead" {
  serve "$AUTHORIZED_OPTIONS"
  run ssh -F /dev/null -p "$port" -i user -o IdentitiesOnly=yes -o BatchMode=yes -o StrictHostKeyChecking=no \
    -o UserKnownHostsFile=/dev/null -o GlobalKnownHostsFile=/dev/null localhost "touch $PWD/shell-ran" </dev/null
  [ ! -e shell-ran ]
  unchanged
}

@test "control, a forced internal-sftp without -R: the same put succeeds" {
  serve 'restrict,command="internal-sftp"'
  sftp_as_user "put $PWD/upload $PWD/store/repo.git/hooks/post-checkout"
  [ "$status" -eq 0 ]
  [ "$(<store/repo.git/hooks/post-checkout)" = payload ]
}
