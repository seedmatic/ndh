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
    enable = false;

    brews = [
    ];

    casks = [
      # social
      "google-drive"
      "notion"
      "signal"

      # knowledge base
      "obsidian"
      #      "zotero"

      # ide
      #      "visual-studio-code" -> nix

      # social
      "keybase"
    ];
  };
}
