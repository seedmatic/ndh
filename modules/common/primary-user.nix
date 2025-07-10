{
  config,
  lib,
  options,
  ...
}:
# module used courtesy of @i077 - https://github.com/i077/system/
let
  inherit (lib) mkAliasDefinitions mkOption types;

  cfgUser = config.profile.user;
  cfgUserName = config.profile.user.name;
in
{

  options = {

    user = mkOption {
      description = "Primary user configuration";
      type = types.attrs;
      default = { };
    };

    hm = mkOption {
      description = "Home Manager configuration";
      type = types.attrs;
      default = { };
    };

  };

  config = {

    # hm -> home-manager.users.<primary user>.hm
    home-manager.users.${cfgUserName} = mkAliasDefinitions options.hm;

    # user -> users.users.<primary user>.user
    users.users.${cfgUserName} = mkAliasDefinitions options.user;

  };

}
