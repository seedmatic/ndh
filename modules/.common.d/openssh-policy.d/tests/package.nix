# The client-side host-key revocation, and a missing host key stopping sshd, as a flake check: a real sshd
# on loopback and a real ssh client.
{ pkgs }:
pkgs.runCommand "openssh-revoked-host-keys-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      coreutils
      gawk
      openssh
    ];
  }
  ''
    cp -r ${./.} tests && chmod -R u+w tests
    cd tests && HOME=$TMPDIR bats .
    touch $out
  ''
