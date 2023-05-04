{...}: {
  homebrew = {
    brews = [
      # social
      "brave-browser"
      "discord"
      "dropbox"
      "google-drive"
      "keybase"
      "messenger"
      "notion"
      "signal"
      "slack"
      "zoom"
    ];

    casks = [
      # ide
      #      "visual-studio-code" -> nix

      # social
      #      "zotero" -> nix
      #      "obsidian" -> nix
    ];
  };
  programs = {
    # crypto
    gpg.enable = true;
    password-store.enable = true;
    oath-toolkit = {
      enable = true;
    };
    # shell 
    powerline-go.enable = false; # prompt
    zoxide.enable = true;        # cd
    # document viewer
    zathura.enable = true;
  };
}
