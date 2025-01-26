{ config, pkgs, lib, ... }: let
  profile = {
    name = "committed";
    email = "stephane.lacoin@gmail.com";
    username = "nxmatic";
    description = "Stephane Lacoin (aka nxmatic)";
  };
in {

  imports = [
    ( import ./common.nix { inherit config pkgs lib profile; } ) 
  ];

}
