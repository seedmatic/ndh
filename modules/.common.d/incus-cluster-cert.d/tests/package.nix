# incus-cluster-cert-renew's bats suite as a flake check: the real path up to the mint.
{ pkgs }:
pkgs.runCommand "incus-cluster-cert-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
      openssl
      yq-go
    ];
  }
  ''
    # The whole .common.d: the guard-uniformity case reads the other scripts that handle a private.
    cp -r ${../..} common && chmod -R u+w common
    cd common/incus-cluster-cert.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
