{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.git = {
    includes = [
      { path = "dotfiles"; }
      { path = "filters"; }
      { path = "local"; }
    ];
  };

  xdg.configFile.git = {
    source = ./git;
    recursive = true;
  };
}
