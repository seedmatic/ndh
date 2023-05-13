{...}: {
  homebrew = {
    brews = [
      # social
      "google-drive"
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
  # programs = {
  #   # crypto
  #   discord.enable = true;
  #   dropbox.enable = true;
  #   gpg.enable = true;
  #   password-store.enable = true;
  #   oath-toolkit.enable = true;
  #   # social
  #   brave.enable = true;
  #   keybase.enable = true;
  #   slack.enabled = true;
  #   zoom-us.enable = true;
  #   # editor
  #   emacs-nox.enable = true;
  #   # shell 
  #   powerline-go.enable = true;  # prompt
  #   zoxide.enable = true;        # cd
  #   # document viewer
  #   zathura.enable = true;
  # };
  services = {
    emacs.enable = true;
  };
}
