#!/usr/bin/env bats
#
# What the operator seat serves a guest's sshfs key — its forced `internal-sftp -R`, which runs sftp-server's
# code in sshd — refuses every write, through a REAL sftp client talking to a REAL `sftp-server -R` (sftp
# -D, no ssh in between: internal-sftp exists only inside sshd). Each write
# is also run against the same server without -R, which must succeed: a refusal that would happen anyway
# proves nothing about -R. SFTP_SERVER is the binary: /usr/libexec/sftp-server on the seat, nixpkgs' in
# the sandbox.

bats_require_minimum_version 1.5.0

setup() {
  t="$BATS_TEST_TMPDIR"
  : "${SFTP_SERVER:?the sftp-server binary to test}"
  mkdir -p "$t/store/repo.git/hooks" "$t/out"
  printf 'ref: refs/heads/develop\n' >"$t/store/repo.git/HEAD"
  printf 'payload\n' >"$t/upload"
  snapshot="$(cd "$t/store" && find . -exec ls -ld {} + | sort)"
}

# sftp <-R or empty> <batch command> — one command, so a refused write fails the run.
sftp_run() {
  local flags=$1
  shift
  printf '%s\n' "$@" >"$t/batch"
  run sftp -q -b "$t/batch" -D "$SFTP_SERVER $flags -d $t/store"
}
unchanged() { [ "$(cd "$t/store" && find . -exec ls -ld {} + | sort)" = "$snapshot" ]; }

@test "read-only: a get works" {
  sftp_run -R "get repo.git/HEAD $t/out/HEAD"
  [ "$status" -eq 0 ]
  [ "$(<"$t/out/HEAD")" = "ref: refs/heads/develop" ]
  unchanged
}

@test "read-only: a put is refused, and the control without -R writes it" {
  sftp_run -R "put $t/upload repo.git/hooks/post-checkout"
  [ "$status" -ne 0 ]
  [ ! -e "$t/store/repo.git/hooks/post-checkout" ]
  unchanged
  sftp_run "" "put $t/upload repo.git/hooks/post-checkout"
  [ "$status" -eq 0 ]
  [ -e "$t/store/repo.git/hooks/post-checkout" ]
}

@test "read-only: an overwrite of an existing file is refused" {
  sftp_run -R "put $t/upload repo.git/HEAD"
  [ "$status" -ne 0 ]
  [ "$(<"$t/store/repo.git/HEAD")" = "ref: refs/heads/develop" ]
  unchanged
}

@test "read-only: a mkdir is refused, and the control without -R makes it" {
  sftp_run -R "mkdir repo.git/refs"
  [ "$status" -ne 0 ]
  unchanged
  sftp_run "" "mkdir repo.git/refs"
  [ "$status" -eq 0 ]
  [ -d "$t/store/repo.git/refs" ]
}

@test "read-only: an rm is refused, and the control without -R removes it" {
  sftp_run -R "rm repo.git/HEAD"
  [ "$status" -ne 0 ]
  unchanged
  sftp_run "" "rm repo.git/HEAD"
  [ "$status" -eq 0 ]
  [ ! -e "$t/store/repo.git/HEAD" ]
}

@test "read-only: a rename, an rmdir, a chmod and a symlink are refused" {
  for op in "rename repo.git/HEAD repo.git/ORIG" "rmdir repo.git/hooks" "chmod 777 repo.git/HEAD" \
    "symlink /etc/passwd repo.git/hooks/pre-commit"; do
    sftp_run -R "$op"
    [ "$status" -ne 0 ]
    unchanged
  done
}
