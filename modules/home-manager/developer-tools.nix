# Common home-manager-scope developer tools.
# Enables BrowserOS neo (secondary browser for AI agents).
# Host-specific omo provider config is imported separately by each host
# (hosts/<host>/modules/home-manager/omo.nix).
{
  config,
  lib,
  pkgs,
  ...
}:

{
  imports = [
    ./browseros.nix
  ];

  ndh.browseros.enable = true;
}
