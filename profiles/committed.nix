{ pkgs, lib, userMapping, ... }:
let 
  inherit (lib) mkDefault;
  committedUser = userMapping.profileUsers.committed;
  workUser = userMapping.profileUsers.work;
in {
  imports = [ ./common.nix ];
  profile = {
    name = mkDefault "committed";
    email = mkDefault committedUser.email;
    homeSymlinks = [ workUser.name ];
    user = {
      name = mkDefault committedUser.name;
      description = mkDefault committedUser.description;
      shell = mkDefault pkgs.zsh;
  uid = 501;
  gid = 501;
    };
  };
  ids.gids.nixbld = lib.mkForce 350;
}