# ssh-keys-renew's bats suite as a flake check: a real sops and a throwaway age key.
{ pkgs }:
pkgs.runCommand "ssh-keys-renew-bats"
  {
    nativeBuildInputs = with pkgs; [
      age
      bats
      bash
      coreutils
      git
      gnugrep
      gnused
      openssh
      sops
      yq-go
    ];
  }
  ''
    cp -r ${./..} renew && chmod -R u+w renew
    cd renew/tests && HOME=$TMPDIR bats .
    touch $out
  ''
