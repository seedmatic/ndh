{...}: {
  homebrew = {
    brews = [
    ];
    casks = [
      # development
      #      "awscli" # -> asdf

      # social
      "microsoft-outlook"
      "microsoft-teams"
    ];
    masApps = {};
  };
  programs = {
    home-manager = {
      krew.enable = true;
    };
  };
}
