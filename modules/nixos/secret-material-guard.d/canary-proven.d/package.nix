# ndh-canary-proven: the only writer of the canary's record (record.sh). A seat tool: it builds the on-demand canary
# by revision through the seat's nix and its linux builder.
{ pkgs }:
pkgs.writeShellApplication {
  name = "ndh-canary-proven";
  runtimeInputs = with pkgs; [
    coreutils
    git
    gnugrep
  ];
  text = builtins.readFile ./record.sh;
}
