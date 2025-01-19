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
      "homebrew/services"
    ];

    casks = [
      # desktop
      #"amethyst"
      #"hyperkey"
      # "appcleaner"
      #
      # "keybase"
    ];
  };
}
