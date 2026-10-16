# The client-side host-key revocation, and a missing host key stopping sshd, as a flake check: a real sshd
# on loopback and a real ssh client.
{ pkgs }:
pkgs.runCommand "openssh-revoked-host-keys-bats"
  {
    NSS_WRAPPER_LIB = "${pkgs.nss_wrapper}/lib/libnss_wrapper.so";
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
