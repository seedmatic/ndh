# flox-config: sets keys of flox's user config one by one (flox-config.sh). One definition, built with the caller's
# pkgs: the home-manager module for a machine, the check for its own system.
{ pkgs }:
pkgs.writeShellApplication {
  name = "flox-config";
  runtimeInputs = with pkgs; [
    coreutils
    dasel
    diffutils
    gawk
    yq-go
  ];
  text = builtins.readFile ./flox-config.sh;
}
