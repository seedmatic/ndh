# ndh-switch's bats suite as a flake check: the real script against a fake GitHub and recording stubs.
{ pkgs }:
pkgs.runCommand "ndh-switch-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      git
      gnugrep
      gnused
      jq
    ];
  }
  ''
    cp -r ${../.} ndh-switch.d && chmod -R u+w ndh-switch.d
    cd ndh-switch.d/tests && HOME=$TMPDIR bats .
    touch $out
  ''
