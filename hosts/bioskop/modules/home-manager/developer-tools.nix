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
    ../../../../modules/home-manager/browseros.nix
    ./omo.nix
  ];

  ndh.browseros.enable = true;
}
