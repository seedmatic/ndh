# ssh-keys-renew's bats suite as a flake check: a real sops and a throwaway age key: the seat-side signer.
{ pkgs }:
pkgs.runCommand "ssh-keys-certify-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      gawk
      git
      gnugrep
      gnused
      openssh
      sops
      yq-go
    ];
  }
  ''
    cp -r ${./..} certify && chmod -R u+w certify
    cd certify/tests && HOME=$TMPDIR bats .
    touch $out
  ''
