# tart:vm:recreate's guard as a darwin flake check: the real activation.sh's functions against stub diskutil and
# plutil (the sandbox has neither). Nothing here touches a VM or a disk image.
{ pkgs }:
pkgs.runCommand "tart-recreate-guard-bats"
  {
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
      yq-go
    ];
  }
  ''
    cp -r ${../.} tart-config.d && chmod -R u+w tart-config.d
    cd tart-config.d/tests && HOME=$TMPDIR bats --print-output-on-failure recreate-guard.bats
    touch $out
  ''
