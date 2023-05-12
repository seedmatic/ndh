{
  config,
  pkgs,
  lib,
  ...
}: {

  xdg.dataFile = {

    raycast = lib.mkIf pkgs.stdenvNoCC.isDarwin {
      source = ./raycast;
      recursive = true;
    };

  };

  xdg.configFile = {

    "nixpkgs/config.nix".source = ../../config.nix;

    hammerspoon = lib.mkIf pkgs.stdenvNoCC.isDarwin {
      source = ./hammerspoon;
      recursive = true;
    };

    zfunc = {
      source = ./zfunc;
      recursive = true;
    };

    # npmrc = {
    #   text = ''
    #     prefix = ${config.home.sessionVariables.NODE_PATH};
    #   '';
    #   target = "nodejs/.npmrc";
    # };

    yabai = lib.mkIf pkgs.stdenvNoCC.isDarwin {
      source = ./yabai;
      recursive = true;
    };

    kitty = lib.mkIf pkgs.stdenvNoCC.isDarwin {
      source = ./kitty;
      recursive = true;
    };

  };

  imports = [
    ./git.nix
  ];

}
