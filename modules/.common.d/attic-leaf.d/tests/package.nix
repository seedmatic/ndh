# attic-leaf-sign's bats suite as a flake check: the real path, through to the served leaf.
{ pkgs }:
pkgs.runCommand "attic-leaf-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
      openssl
      step-cli
      yq-go
    ];
  }
  ''
    cp -r ${../.} attic-leaf.d && chmod -R u+w attic-leaf.d
    cd attic-leaf.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
