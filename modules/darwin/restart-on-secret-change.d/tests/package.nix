# restart-on-secret-change's bats suite as a flake check: fake generations, launchctl and id stubbed.
{ pkgs }:
pkgs.runCommand "restart-on-secret-change-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      diffutils
    ];
  }
  ''
    cp -r ${./..} restart && chmod -R u+w restart
    cd restart/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
