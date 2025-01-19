{ pkgs, ... }:
let

  tailnet = {
    name = "mammoth-skate";
    domain = "ts.net";
  };

  host = {
    inherit tailnet;

    name = "bioskop";
  }; 

  user = {
      name = "nxmatic";
      email = "stephane.lacoin@gmail.com";
      description = "Stephane Lacoin (aka nxmatic)";
      home = builtins.toPath "/Users/nxmatic";
      shell = pkgs.zsh;
    };

  profile = {
    inherit host user;

    name = "committed";
  };

in {
  inherit profile;

  imports = [ ./common.nix ];
}