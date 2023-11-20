{
  config,
  lib,
  pkgs,
  ...
}: {
  user.name = "stephane.lacoin";

  hm = {
    imports = [
      ../home-manager/work.nix
    ];
  };

  homebrew = {
    enable = true;

    brews = [
    ];

    casks = [
      # social
      # "notion"

      # knowledge base
      # "obsidian"
      #      "zotero"

      # social
      # "keybase"
    ];
  };
}
