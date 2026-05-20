{
  config,
  lib,
  ...
}:
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

    services.rke2labOverlay.enable = true;
  };
}
