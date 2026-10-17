# ndh-switch, the sessions' one switch verb (see ndh-switch.sh). Imported by the darwin module, which puts it on
# the operator seat's PATH, and by the flake's app and checks: one definition.
{ pkgs, seat }:
pkgs.writeShellApplication {
  name = "ndh-switch";
  runtimeInputs = with pkgs; [
    coreutils
    git
    jq
    nixos-rebuild-ng
    openssh
  ];
  text = ''
    machines=${./machines.json}
    seat=${pkgs.lib.escapeShellArg seat}
  ''
  + builtins.readFile ./ndh-switch.sh;
}
