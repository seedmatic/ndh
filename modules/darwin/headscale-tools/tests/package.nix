# hs's bats suite as a flake check: the real hs and hs-lib, the real logger, stub headscale and sops.
{ pkgs }:
pkgs.runCommand "hs-bats"
  {
    NDH_LOGGER_SH = ../../../.common.d/shell.d/logger.sh;
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gawk
      gnugrep
      gnused
      yq-go
    ];
  }
  ''
    cp -r ${./..} ht && chmod -R u+w ht
    cd ht/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
