# ndh-claude-wake (see ndh-claude-wake.sh), built for one seat's VS Code. Imported by the darwin module, which puts it
# on the seat's PATH, and by the flake's app and checks: one definition.
{
  pkgs,
  registry,
  bundle,
  scheme,
}:
pkgs.writeShellApplication {
  name = "ndh-claude-wake";
  runtimeInputs = with pkgs; [
    coreutils
    gnugrep
    yq-go
  ];
  text = ''
    registry=${pkgs.lib.escapeShellArg registry}
    bundle=${pkgs.lib.escapeShellArg bundle}
    scheme=${pkgs.lib.escapeShellArg scheme}
    settle=5
  ''
  + builtins.readFile ./ndh-claude-wake.sh;
}
