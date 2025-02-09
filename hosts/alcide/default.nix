{ pkgs, ... }:
let

  tailnet = {
    name = "mammoth-skate";
    domain = "ts.net";
  };

  host = {
    inherit tailnet;

    name = "alcide";
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

}