# The client-side host-key revocation through the fleet's KRL (its builder, keys-yaml.d/krl.sh, and its
# refusals), and a missing host key stopping sshd, as a flake check: a real sshd on loopback and a real
# ssh client.
{ pkgs }:
pkgs.runCommand "openssh-revoked-host-keys-bats"
  {
    NSS_WRAPPER_LIB = "${pkgs.nss_wrapper}/lib/libnss_wrapper.so";
    KRL_SH = ../../keys-yaml.d/krl.sh;
    nativeBuildInputs = with pkgs; [
      bash
      bats
      coreutils
      gawk
      gnugrep
      openssh
      yq-go
    ];
  }
  ''
    cp -r ${./.} tests && chmod -R u+w tests
    cd tests && HOME=$TMPDIR bats .
    touch $out
  ''
