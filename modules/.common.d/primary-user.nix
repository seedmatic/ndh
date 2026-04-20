{
  config,
  lib,
  options,
  ndh,
  ...
}:
# module used courtesy of @i077 - https://github.com/i077/system/
let
  inherit (lib) mkAliasDefinitions mkOption types;

  ndhContext = ndh.context;
  cfgUser = config.profile.user;
  cfgUserName = config.profile.user.name;
  hostProfile = ndhContext.hostProfile;
  homeManagerEnabled =
    if
      hostProfile != null && hostProfile ? enableHomeManager && hostProfile.enableHomeManager != null
    then
      hostProfile.enableHomeManager
    else
      true;
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

  config = lib.mkMerge [
    {
      # user -> users.users.<primary user>.user
      users.users.${cfgUserName} = mkAliasDefinitions options.user;
    }
    (
      if homeManagerEnabled && options ? home-manager then
        {
          # hm -> home-manager.users.<primary user>.hm (only when Home Manager module is loaded)
          home-manager.users.${cfgUserName} = mkAliasDefinitions options.hm;
        }
      else
        { }
    )
  ];

}
