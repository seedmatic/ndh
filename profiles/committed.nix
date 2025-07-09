{ pkgs, lib, ... }:
let inherit (lib) mkDefault;
in {
  imports = [ ./common.nix ];
  profile = {
    name = mkDefault "work";
    email = mkDefault "stephane.lacoin@gmail.com";
    user = {
      name = mkDefault "nxmatic";
      description = mkDefault "Stephane Lacoin (aka nxmatic)";
      shell = mkDefault pkgs.zsh;
    };
  };
  ids.gids.nixbld = lib.mkForce 350;
}