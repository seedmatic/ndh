{
  pkgs,
  lib,
  ndh,
  ...
}:
let
  inherit (lib) mkDefault;
  ndhContext = ndh.context;
  catalog = ndhContext.catalog;
  users = catalog.users;
  committedUser = users.committed;
  workUser = users.work;
in
{
  imports = [ ./.common.nix ];
  profile = {
    name = mkDefault "work";
    email = mkDefault workUser.email;
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
