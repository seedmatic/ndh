{pkgs, ...}: {
  home.packages = with pkgs; [
    nixpkgs-fmt
    #    nix-lsp
    nil
  ];

  programs.vscode.extensions = with pkgs.vscode-extensions; [
    jnoortheen.nix-ide
  ];

  # settings = {
  #   # "nix.enableLanguageServer" = true;
  #   "nix.formatterPath" = "${nixpkgs-fmt}/bin/nixpkgs-fmt";
  #   "nix.serverPath" = "${nix-lsp}/bin/nix-lsp";
  # };
}
