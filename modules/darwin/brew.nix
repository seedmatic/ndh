{...}: {
  homebrew = {
    enable = true;
    global = {
      brewfile = true;
    };
    brews = [
    ];

    taps = [
      # base
      "homebrew/bundle"
      "homebrew/cask-fonts"
      "homebrew/cask-versions"
      "homebrew/services"
      # crypto
      "1password/tap"
    ];
    casks = [
      # desktop
      "raycast"
      "alt-tab"
      "appcleaner"
      "hammerspoon"

      # crypto (should move in profiles)
      "1password"
      "1password-cli"

      # terminal
      #      "kitty" -> nix
    ];
  };
}
