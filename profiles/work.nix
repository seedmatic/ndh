{ pkgs, lib, userMapping, ... }:
let
  inherit (lib) mkDefault;
  committedUser = userMapping.profileUsers.committed;
  workUser = userMapping.profileUsers.work;
in {
  imports = [ ./common.nix ];
  profile = {
    name = mkDefault "work";
    email = mkDefault workUser.email;
    homeSymlinks = [ committedUser.name ];
    user = {
      name = mkDefault workUser.name;
      description = mkDefault workUser.description;
      shell = mkDefault pkgs.zsh;
      uid = 503;
      gid = 503;
    };
  };
  ids.gids.nixbld = lib.mkForce 350;
}
