# The sshd post-flight checks' bats suite as a flake check, on the real logger wrapper.
{ pkgs }:
pkgs.runCommand "openssh-checks-bats"
  {
    NDH_LOGGER_SH = ../../../../.common.d/shell.d/logger.sh;
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gawk
      gnugrep
      gnused
      openssh
      yq-go
    ];
  }
  ''
    cp -r ${./..} openssh && chmod -R u+w openssh
    cd openssh/tests && HOME=$TMPDIR bats --print-output-on-failure .
    touch $out
  ''
