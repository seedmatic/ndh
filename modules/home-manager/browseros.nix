{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.ndh.browseros or { enable = true; };
  enable = cfg.enable or true;
in
{
  options.ndh.browseros = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Install BrowserOS neo (secondary browser for AI agents) into ~/Applications.";
    };
  };

  config = mkIf enable {
    home.file."Applications/BrowserOS neo.app" = {
      source = "${pkgs.browseros-neo}/Applications/BrowserOS neo.app";
      recursive = true;
    };

    home.packages = [ pkgs.browseros-neo ];
  };
}
