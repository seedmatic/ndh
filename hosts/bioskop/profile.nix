{ hostProfile, darwinProfile }:
{
  config,
  ...
}:
{
  imports = [
    (import ../host-common.nix {
      inherit hostProfile darwinProfile;
      # No `headscaleServerUrl` — fall through to
      # `catalog.headscale.aliasUrl` (headscale.mammoth-skate.local),
      # which tracks whichever host currently holds `role = "primary"`
      # via mDNS.  Port 41841 documented at catalog/headscale/default.nix.
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

    # Headscale role assignments (primary/standby) are Darwin-specific
    # today — the Darwin LaunchAgent is the bootstrap control-plane.
    # They live in hosts/bioskop/darwin.nix, not here, so the NixOS
    # VM hosted on bioskop does not inherit the role and run a second
    # daemon (the exactly-one-primary invariant requires the VM to
    # stay at role = "none" for now).
  };
}
