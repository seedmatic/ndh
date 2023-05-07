{
  config,
  pkgs,
  lib,
  ...
}: {
  programs.neovim = {
    plugins = with pkgs.vimPlugins; [
      (config.lib.vimUtils.pluginGit "HEAD" "wbthomason/packer.nvim")
    ];
    extraConfig = ''
    ${config.lib.vimUtils.readVimConfig ./plugins.lua}
    '';
  };
}

