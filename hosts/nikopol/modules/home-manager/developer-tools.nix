{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Developer tools configuration for nikopol (Darwin)
  # Enables Claude Code settings management and Comet browser with remote debugging

  imports = [
    ../../../../modules/home-manager/claude-code.nix
    ../../../../modules/home-manager/comet-debug.nix
  ];

  ndh.claude-code.enable = true;

  ndh.cometDebug = {
    enable = true;
    debugPort = 9222;
  };
}
