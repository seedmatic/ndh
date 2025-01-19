{
  config,
  lib,
  options,
  ...
}:
# module used courtesy of @i077 - https://github.com/i077/system/
let
  inherit (lib) mkAliasDefinitions mkOption types;

  userName = config.profile.user.name;
in
{

  # hm -> home-manager.users.<primary user>.hm
  home-manager.users.${userName} = mkAliasDefinitions options.hm;

  # user -> users.users.<primary user>.user
  users.users.${userName} = mkAliasDefinitions [
    "options"
    "profile"
    "user"
  ];

}
