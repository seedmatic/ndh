{ config, lib, pkgs, ... }:

let
  inherit (lib) mkDefault;

  cfg = config.profile;
  user = cfg.user;
  userName = user.name;
  userHome = cfg.user.home;

  mkPkg = name: pkgPath: extra: ({ inherit name; pkg-path = pkgPath; } // extra);

in

{
  programs.flox = {
    enable = mkDefault true;

    packages = mkDefault [
      (mkPkg "home-manager" "home-manager" { })
      (mkPkg "keychain" "keychain" { })
      (mkPkg "linux-builder" "darwin.linux-builder" {
        systems = [ "aarch64-darwin" ];
      })
      (mkPkg "pass" "pass" { })
      (mkPkg "lldpd" "lldpd" { })
      (mkPkg "git" "git" { })
      (mkPkg "git-town" "git-town" { })
      (mkPkg "gitflow" "gitflow" { })
    ];

    pullRemotes = mkDefault [
      {
        name = "home";
        remote = "nxmatic/home";
        dir = userHome;
      }
      {
        name = "git";
        remote = "nxmatic/git";
        dir = "${userHome}/Gits";
      }
      {
        name = "lima";
        remote = "nxmatic/lima";
        dir = "${userHome}/.lima";
      }
    ];
  };
}
