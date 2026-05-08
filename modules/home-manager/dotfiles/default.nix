{ pkgs, lib, self, ... }:
let
  nixpkgsConfigFile = "${self}/modules/.common.d/nixpkgs-config.nix";
in
{
  xdg.dataFile = {
    raycast = lib.mkIf pkgs.stdenvNoCC.isDarwin {
      source = ./raycast;
      recursive = true;
    };
  };

  xdg.configFile = {
    "nixpkgs/config.nix".source = nixpkgsConfigFile;

    # hammerspoon = lib.mkIf pkgs.stdenvNoCC.isDarwin {
    #   source = ./hammerspoon;
    #   recursive = true;
    # };

    zfunc = {
      source = ./zfunc;
      recursive = true;
    };

    # npmrc = {
    #   text = ''
    #     prefix = ${config.home.sessionVariables.RKE2_NODEPATH};
    #   '';
    #   target = "nodejs/.npmrc";
    # };

  };

}
