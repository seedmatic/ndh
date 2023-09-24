{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.git = {
    includes = [
      {path = "githooks";}
      {path = "dotfiles";}
      {path = "local";}
    ];
  };

  xdg.configFile.git = {
    source = ./git;
    recursive = true;
  };

  home.sessionVariables = {
    ZDOTGIT_DIR = "${config.xdg.dataHome}/zdot/bare-repository.git";
  };
}
