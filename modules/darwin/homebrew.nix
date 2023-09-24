{...}: {
  homebrew = {
    enable = false;

    global = {
      brewfile = true;
    };

    brews = [
    ];

    taps = [
      # base
      "homebrew/bundle"
      "homebrew/cask" # Required for casks
      "homebrew/cask-fonts"
      "homebrew/cask-versions"
      "homebrew/services"
    ];

    casks = [
      # desktop
      "appcleaner"
      #
      "keybase"
    ];
  };
}
