# content-guard as a command, for whatever leaves a metalspace.
{ pkgs }:
pkgs.writeShellApplication {
  name = "content-guard";
  runtimeInputs = with pkgs; [
    findutils
    gawk
    gnugrep
  ];
  text = builtins.readFile ./content-guard.sh;
}
