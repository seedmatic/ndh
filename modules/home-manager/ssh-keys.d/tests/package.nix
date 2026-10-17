# The operator's KnownHostsCommand (ssh.d/scripts/ca-known-hosts-command.sh) as a flake check, under the
# real logger: the host authority is vouched for the fleet's names only.
{ pkgs }:
pkgs.runCommand "ssh-known-hosts-command-bats"
  {
    NDH_LOGGER_SH = ../../../.common.d/shell.d/logger.sh;
    KNOWN_HOSTS_COMMAND = ../../ssh.d/scripts/ca-known-hosts-command.sh;
    nativeBuildInputs = with pkgs; [
      bats
      bash
      coreutils
      gnugrep
      gnused
      openssh
    ];
  }
  ''
    HOME=$TMPDIR bats --print-output-on-failure ${./known-hosts-command.bats}
    touch $out
  ''
