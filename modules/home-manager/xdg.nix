{
  config,
  pkgs,
  ...
}: {
  xdg = {
    enable = true;

    cacheHome = config.home.homeDirectory + "/.local/var/cache";

    userDirs = {
      enable = pkgs.stdenv.isLinux;
    };
  };
}
