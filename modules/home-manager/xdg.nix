{
  config,
  pkgs,
  ...
}: {
  xdg = {
    enable = true;

    # Use standard XDG paths instead of macOS-specific locations
    # This ensures git looks in ~/.config/git/config instead of ~/Library/Preferences/git/config
    # These paths must match what zdotdir's zshenv.zsh sets
    configHome = config.home.homeDirectory + "/.config";
    dataHome = config.home.homeDirectory + "/.local/share";
    stateHome = config.home.homeDirectory + "/.local/state";
    cacheHome = config.home.homeDirectory + "/.cache";

    userDirs = {
      enable = pkgs.stdenv.isLinux;
    };
  };
}
