{lib, pkgs, ...}: {

  user.name = "stephane.lacoin";
  
  hm = {
    imports = [
      ../home-manager/committed.nix
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
      "zotero"

      # ide
      #      "visual-studio-code" -> nix

      # social
    ];
  };


}

