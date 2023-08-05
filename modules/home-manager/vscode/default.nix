{ pkgs, ... }: {
  imports =
    [
      ./extensions.nix
    ];


  programs.vscode = {

    enable = true;

    # Snippet to use insiders build
    # package = pkgs.vscode-fhs;
    # package = pkgs.vscodium;
    #package =
    #  (pkgs.vscode.override {
    #    isInsiders = true;
    #  }).overrideAttrs (oldAttrs: rec {
    #    src = (builtins.fetchTarball {
    #      url = "https://code.visualstudio.com/sha/download?build=insider&os=linux-x64";
    #      sha256 = "13mk70fga643xhxf8lijmfkxk51dsfn36lbg51x99s77yabw3wcw";
    #    });
    #    version = "latest";
    #  });


    # extensions = with pkgs.vscode-extensions; [
    #  vscodevim.vim
    #  jnoortheen.nix-ide
    # ];

    # programmatic settings can't coexist with manual ones because https://github.com/microsoft/vscode/issues/15909 😢
    # userSettings = {
    #   "vim.useSystemClipboard" = true;
    #   "vim.highlightedyank.enable" = true;
    #   # "workbench.colorTheme" = "Default Dark+";
    #   "editor.minimap.enabled" = false;
    # };
  };
}
