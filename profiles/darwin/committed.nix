{
  config,
  lib,
  pkgs,
  ...
}: {
  user.name = "nxmatic";

  hm = {
    imports = [
      ../home-manager/committed.nix
    ];
  };

  homebrew = {
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
