{ pkgs, ... }:
let
  inherit (pkgs) lib fetchgit fetchurl fetchFromGitHub dockerTools;
  unfreeAllowed = pkgs.config ? allowUnfree && pkgs.config.allowUnfree == true;
  system = pkgs.stdenv.hostPlatform.system;
  nvSources = import ../../../.nvfetcher/generated.nix {
    inherit fetchgit fetchurl fetchFromGitHub dockerTools;
  };
  insidersArtifacts = {
    "x86_64-linux" = {
      source = nvSources.vscode-insiders-linux-x64;
      extension = "tar.gz";
    };
    "aarch64-linux" = {
      source = nvSources.vscode-insiders-linux-arm64;
      extension = "tar.gz";
    };
    "x86_64-darwin" = {
      source = nvSources.vscode-insiders-darwin-x64;
      extension = "zip";
    };
    "aarch64-darwin" = {
      source = nvSources.vscode-insiders-darwin-arm64;
      extension = "zip";
    };
  };
  artifact =
    let resolved = lib.attrByPath [ system ] null insidersArtifacts;
    in if resolved == null then
      throw "VS Code Insiders download unsupported for ${system}"
    else
      resolved;
  repackedSrc = pkgs.runCommand "${artifact.source.pname}.${artifact.extension}" { } ''
    cp ${artifact.source.src} $out
  '';
in {
  imports = [ ./extensions.nix ];

  programs.vscode = {

    enable = unfreeAllowed;

    # Snippet to use insiders build
    # package = pkgs.vscode-fhs;
    # package = pkgs.vscodium;
      package =
       (pkgs.vscode.override {
         isInsiders = true;
       }).overrideAttrs (oldAttrs: rec {
         src = repackedSrc;
         inherit (artifact.source) version;
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
