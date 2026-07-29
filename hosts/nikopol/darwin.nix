{ halfRamMiB }:
{ lib, ... }:
{
  config = {
    # Nikopol is the headscale standby: CLI + config materialised so
    # the host is promotion-ready, but neither the daemon nor the
    # mdns-publish agent run until the operator flips this to
    # "primary" (and simultaneously demotes bioskop).  Darwin-scoped
    # so the NixOS VM does not inherit the role.
    services.headscaleBootstrap.role = "standby";

    # Keep Darwin user home aligned with vm-mounted persistent volume.
    profile.user.home = lib.mkForce (builtins.toPath "/Volumes/user-home");

    services.nxmaticCachixWatchStore = {
      enable = true;
      sopsEncryptedTokenFile = ../../.secrets;
    };

    lima.configGenerator = {
      installMaterializerPackage = false;
    };

    tart.configGenerator = {
      forceEnable = false;
      installMaterializerPackage = false;
      vmMemoryMiB = halfRamMiB;
      # When the operator deploys nikopol's run manifest to a vz host
      # via `nerd-tart-nikopol-deploy`, the wrapper there reads these
      # defaults.  Mirror bioskop's headless+screen-bridge combo so the
      # boot flow is identical regardless of which Mac runs the VM.
      # `Wi-Fi` is the canonical hardware-port name on macOS; reliable
      # on laptops where a Thunderbolt adapter may not be plugged in.
      vmRunBridgeInterface = "Wi-Fi";
      vmRunSerialBridgeEnable = true;
      vmRunSerialBridgeAutoScreen = true;
    };

    # Vector observability aggregator for NixOS disk image builds
    bringupObserve = {
      enable = true;
      # Darwin host acts as the aggregator (no upstream endpoint)
      # NixOS VMs forward to this via upstreamEndpoint in their configs
    };
  };
}
