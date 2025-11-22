{ config, lib, pkgs, ... }:

let
  inherit (lib) mkDefault;

  mkPkg = name: pkgPath: extra: ({ inherit name; pkg-path = pkgPath; } // extra);

  # Use a safe default path that works in both Darwin and Home Manager contexts
  projectRoot =
    if config ? home && config.home ? homeDirectory
    then "${config.home.homeDirectory}/Gits/nxmatic/nix-darwin-home"
    else "/Users/nxmatic/Gits/nxmatic/nix-darwin-home";  # fallback for Darwin system context
in

{
  programs.floxEnv = {
    enable = mkDefault true;

    packages = mkDefault [
      (mkPkg "home-manager" "home-manager" { })
      (mkPkg "keychain" "keychain" { })
      (mkPkg "linux-builder" "darwin.linux-builder" {
        systems = [ "aarch64-darwin" "x86_64-darwin" ];
      })
      (mkPkg "nix-tree" "nix-tree" { })
      (mkPkg "nixd" "nixd" { })
      (mkPkg "nixtract" "nixtract" { })
      (mkPkg "nvfetcher" "nvfetcher" { })
      (mkPkg "pass" "pass" { })
      (mkPkg "pstree" "pstree" { })
      (mkPkg "ookla-speedtest" "ookla-speedtest" { })
      (mkPkg "lldpd" "lldpd" { })
      (mkPkg "git" "git" { })
      (mkPkg "git-town" "git-town" { })
      (mkPkg "gitflow" "gitflow" { })
    ];

    supportedSystems = mkDefault [ "aarch64-darwin" "aarch64-linux" "x86_64-darwin" "x86_64-linux" ];
    projectRoot = mkDefault projectRoot;
  };
}
