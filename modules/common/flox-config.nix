{ config, lib, pkgs, ... }:

let
  inherit (lib) mkDefault;

  # Use a safe default path that works in both Darwin and Home Manager contexts
  projectRoot =
    if config ? home && config.home ? homeDirectory
    then "${config.home.homeDirectory}/Gits/nxmatic/nix-darwin-home"
    else "/Users/nxmatic/Gits/nxmatic/nix-darwin-home";  # fallback for Darwin system context
in

{
  # Configure the flox environment options defined in flox-env.nix
  programs.floxEnv = {
    enable = mkDefault true;

    packages = mkDefault [
      {
        name = "home-manager";
        pkg-path = "home-manager";
      }
      {
        name = "keychain";
        pkg-path = "keychain";
      }
      {
        name = "linux-builder";
        pkg-path = "darwin.linux-builder";
        systems = [ "aarch64-darwin" "x86_64-darwin" ];
      }
      {
        name = "nix-tree";
        pkg-path = "nix-tree";
      }
      {
        name = "nixd";
        pkg-path = "nixd";
      }
      {
        name = "nixtract";
        pkg-path = "nixtract";
      }
      {
        name = "nvfetcher";
        pkg-path = "nvfetcher";
      }
      {
        name = "pass";
        pkg-path = "pass";
      }
      {
        name = "pstree";
        pkg-path = "pstree";
      }
    ];

    supportedSystems = mkDefault [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
    projectRoot = mkDefault projectRoot;
  };
}
