{
  pkgs,
  lib,
  catalog,
  ...
}:
let
  inherit (lib) mkDefault;
  users = catalog.users;
  committedUser = users.committed;
  workUser = users.work;
in
{
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
