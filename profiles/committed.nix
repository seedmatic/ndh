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
    name = mkDefault "committed";
    email = mkDefault committedUser.email;
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
