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
    # The whole modules tree: the guard-uniformity case reads every script that handles a private,
    # and one of them (git.d/sops.sh) lives outside .common.d.
    cp -r ${../../..} modules && chmod -R u+w modules
    cd modules/.common.d/incus-cluster-cert.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
