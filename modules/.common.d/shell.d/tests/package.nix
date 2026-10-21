# ndh::logger:command:run's bats suite as a flake check, on the real logger.
{ pkgs }:
pkgs.runCommand "logger-command-run-bats"
  {
    NDH_LOGGER_SH = ../logger.sh;
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
    ];
  }
  ''
    HOME=$TMPDIR bats --print-output-on-failure ${./command-run.bats} ${./secret-window.bats}
    touch $out
  ''
