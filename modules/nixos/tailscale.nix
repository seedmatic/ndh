{
  config,
  lib,
  ...
}:
{
  # Auth-backend-agnostic `tailscaled` hardening — applies whenever the
  # daemon is enabled, regardless of which controller enrolls the node
  # (SaaS or self-hosted headscale).  Registration itself (auth key,
  # tags, --login-server, autoconnect ordering) lives in
  # modules/nixos/headscale.nix, which is controller-aware and keys the
  # per-kind auth slot off `ndh.headscaleClient.controller`.  This module
  # only hardens the running daemon, so it must NOT duplicate any
  # registration wiring.
  config = lib.mkIf config.services.tailscale.enable {
    # Force tailscaled to drive netfilter via the native nftables runner
    # instead of shelling out to `iptables` (which on nft-enabled hosts is
    # the iptables-nft compat shim).  The shim in iptables 1.8.13 does not
    # accept tailscale's `--nfmask` extension and fails with
    # "Extension MARK revision 0 not supported, missing kernel module?",
    # which keeps the daemon's netfilter health check red even when
    # peer-to-peer connectivity is up.  Native nftables avoids the shim.
    systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE = "nftables";

    # Trust the Tailscale interface (bypass firewall).  Single source for
    # this across the fleet — every tailscaled instance, gateway or not.
    networking.firewall.trustedInterfaces = [ "tailscale0" ];
  };
}
