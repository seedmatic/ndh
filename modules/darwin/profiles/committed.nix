{
  config,
  lib,
  pkgs,
  ...
}:

let
  # Define profile as an attribute set
  profile = {
    name = "committed";
    user = {
      name = "nxmatic";
      email = "stephane.lacoin@gmail.com";
      description = "Stephane Lacoin (aka nxmatic)";
    };
  };
  
in
  import ../../home-manager/profiles/common.nix { 
    inherit config pkgs lib profile; 
  }
