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

    # Vector observability agent forwards build events to Darwin aggregator
    bringupObserve = {
      enable = true;
      # Forward to Darwin host Vector aggregator via VM network gateway
      # VM NAT makes the macOS host accessible at 192.168.5.2
      upstreamEndpoint = "http://192.168.5.2:9001";
    };
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
