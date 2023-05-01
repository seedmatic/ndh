{...}: {
  homebrew = {
    enable = true;
    global = {
      brewfile = true;
    };
    brews = [
      # # ide
      # "eclipse-installer"
      # "visual-studio-code"

      # crypto
      #      "pass" -> nix
      #      "pass-otp" -> nix
      #      "pass-git-helper" -> nix

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

    taps = [
      "koekeishiya/formulae"
      "teamookla/speedtest"
    ];
    casks = [
      # virtualization
      "utm"

      # containers
      "rancher"

      # ide
      #      "visual-studio-code" -> nix

      # social
      #      "zotero" -> nix
      #      "obsidian" -> nix
    ];
  };
  programs = {
    # crypto
    oath-toolkit = {
      enable = true;
    };
  };
}
