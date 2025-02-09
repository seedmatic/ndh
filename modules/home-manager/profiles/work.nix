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
      name = "stephane.lacoin";
      email = "stephane.lacoin@hyland.com";
      description = "Stephane Lacoin (aka nxmatic)";
      home = builtins.toPath "/Users/stephane.lacoin";
      shell = pkgs.zsh;
    };

  profile = {
    inherit host user;

    name = "work";
  };

in {
  inherit profile;

  imports = [ ./common.nix ];

  ids.gids.nixbld = 30000;

}