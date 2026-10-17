# ndh-ops's bats suite as a flake check: the real script, a throwaway delegation directory, stub tools.
{ pkgs }:
pkgs.runCommand "ndh-ops-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
    ];
  }
  ''
    cp -r ${../.} ndh-ops.d && chmod -R u+w ndh-ops.d
    cd ndh-ops.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
