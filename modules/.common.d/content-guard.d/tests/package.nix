# content-guard's bats suite as a flake check: the shapes refused, their look-alikes passed.
{ pkgs }:
pkgs.runCommand "content-guard-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      findutils
      gawk
      gnugrep
    ];
  }
  ''
    cp -r ${../.} content-guard.d && chmod -R u+w content-guard.d
    cd content-guard.d/tests && bats .
    touch $out
  ''
