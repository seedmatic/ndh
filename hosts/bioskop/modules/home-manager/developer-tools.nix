{
  config,
  lib,
  pkgs,
  ...
}:

{
  # Developer tools configuration for bioskop (Darwin)
  # Enables Claude Code settings management and Comet browser with remote debugging

  imports = [
    ../../../../modules/home-manager/comet-debug.nix
    ../../../../modules/home-manager/browseros.nix
    ./omo.nix
  ];

  # Comet's launchd agent pointed at a non-existent path; disable the broken
  # auto-launch while we move to BrowserOS neo. Comet stays manually usable.
  ndh.cometDebug.enable = false;

  ndh.browseros.enable = true;
}
