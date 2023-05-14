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
    package =
      (pkgs.vscode.override {
        isInsiders = true;
      }).overrideAttrs (oldAttrs: rec {
        src = (builtins.fetchTarball {
          url = "https://code.visualstudio.com/sha/download?build=insider&os=linux-x64";
          sha256 = "1j6xgqiijq6pjsh3n7y16bl93hi5bsbvq34j8br93kg0s7hqzkv0";
        });
        version = "latest";
      });


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
