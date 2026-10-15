# incus-cluster-join's bats suite as a flake check, on the real logger wrapper.
{ pkgs }:
pkgs.runCommand "incus-cluster-join-bats"
  {
    NDH_LOGGER_SH = ../../../modules/.common.d/shell.d/logger.sh;
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
      jq
      yq-go
    ];
  }
  ''
    cp -r ${./..} join && chmod -R u+w join
    cd join/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
