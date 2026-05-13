{ hostProfile, darwinProfile }:
{
  config,
  ...
}:
{
  imports = [
    (import ../host-common.nix {
      inherit hostProfile darwinProfile;
      # URL tracks catalog.headscale.serverUrls.bioskop.  Points at the
      # local LaunchAgent so bootstrap doesn't depend on a not-yet-
      # existing rke2 cluster.  Resolves via mDNS so DHCP-assigned
      # LAN IPs don't invalidate it.  Port 41841 documented at
      # catalog/headscale/default.nix.
      headscaleServerUrl = "http://bioskop.local:41841";
    })
    # Teleport removed - using Headscale for internal network
  ];
  config = {
    # Enable rescue tooling for this host when needed (default is off)
    # rescue.enable = true;

    # Sign locally produced store paths so peer hosts can trust nix copy --from ssh-ng://bioskop
    nix.settings.trusted-users = [
      "builder"
    ];

    # Bioskop is the current primary owner of the headscale alias.
    # Runs the daemon + the mdns-publish agent so clients resolve
    # catalog.headscale.aliasUrl to this host.  See
    # modules/darwin/headscale-daemon.nix for the role semantics.
    services.headscaleBootstrap.role = "primary";
  };
}
