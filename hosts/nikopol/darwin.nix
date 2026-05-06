{ halfRamMiB }:
{ lib, ... }:
{
  config = {
    # Keep Darwin user home aligned with vm-mounted persistent volume.
    profile.user.home = lib.mkForce (builtins.toPath "/Volumes/user-home");

    # Keep /net autofs explicit for Lima disk-image path prerequisites.
    services.nfsDarwin = {
      enable = true;
      autofs.enable = true;
      autofs.mountPoint = "/net";
      autofs.installMaterializerPackage = true;
    };

    services.nxmaticCachixWatchStore = {
      enable = true;
      sopsEncryptedTokenFile = ../../.secrets;
    };

    networking.vlan = {
      enable = true;
      id = 2;
      addressPrefix = "192.168.2";
      parentInterface = "en0";
    };

    lima.configGenerator = {
      installMaterializerPackage = false;
    };

    tart.configGenerator = {
      forceEnable = false;
      installMaterializerPackage = false;
      vmMemoryMiB = halfRamMiB;
    };

    # Vector observability aggregator for NixOS disk image builds
    bringupObserve = {
      enable = true;
      # Darwin host acts as the aggregator (no upstream endpoint)
      # NixOS VMs forward to this via upstreamEndpoint in their configs
    };
  };
}
