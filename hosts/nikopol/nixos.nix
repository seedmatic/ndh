{
  config,
  lib,
  ndh,
  ...
}:
let
  ndhContext = ndh.context;
  hostProfile = ndhContext.hostProfile;
  bringupMode = ndhContext.generationMode == "bringup";
in
{
  config = {
    profile.user.home = lib.mkForce "/home/${config.profile.user.name}";
  }
  // (lib.optionalAttrs (!bringupMode) {
    networking.vlan = {
      enable = true;
      id = 2;
      addressPrefix = "192.168.2";
      parentInterface = "vmlan0";
      addressSourceInterface = "lan-br";
    };
  });
}
