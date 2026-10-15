# baremetal-link deploy's bats suite as a flake check, on the real logger wrapper.
{ pkgs }:
pkgs.runCommand "baremetal-link-deploy-bats"
  {
    NDH_LOGGER_SH = ../../../modules/.common.d/shell.d/logger.sh;
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
    ];
  }
  ''
    cp -r ${./..} deploy && chmod -R u+w deploy
    cd deploy/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
