{ pkgs, lib, config, ... }:
let

  tailnet = {
    name = "mammoth-skate";
    domain = "ts.net";
  };

  host = {
    inherit tailnet;

    name = lib.mkDefault "jdoe";
  }; 

  # Detect system type
  isDarwin = pkgs.stdenv.hostPlatform.isDarwin or false;
  isLinux = pkgs.stdenv.hostPlatform.isLinux or false;

  user = {
    name = "nxmatic";
    description = "Stephane Lacoin (aka nxmatic)";
    #home = if isDarwin then "/Users/nxmatic" else "/home/nxmatic";
    shell = pkgs.zsh;
    homeMode = "0750";
    isNormalUser = true;
    isSystemUser = false;
    group = "users";
  };

  profile = {
    inherit host user;

    name = "committed";
    email = "stephane.lacoin@gmail.com";
  };

in {
  inherit profile;

  imports = [ ./common.nix ];
}