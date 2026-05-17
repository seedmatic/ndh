{ hostProfile, darwinProfile }:
{
  config,
  ...
}:
{
  imports = [
    (import ../host-common.nix {
      inherit hostProfile darwinProfile;
      # No `headscaleServerUrl` override — fall through to
      # `catalog.headscale.aliasUrl` (mammoth-skate.duckdns.org:41841),
      # which works universally for all hosts (on-LAN via NAT hairpinning,
      # off-LAN via WAN port forward).
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
