{ pkgs, lib, ... }:
let

  tailnet = {
    name = "mammoth-skate";
    domain = "ts.net";
  };

  host = {
    inherit tailnet;

    name = lib.mkDefault "jdoe";
  }; 

  user = {
      name = "nxmatic";
      description = "Stephane Lacoin (aka nxmatic)";
      home = builtins.toPath "/Users/nxmatic";
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