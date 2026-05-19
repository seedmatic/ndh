{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  ...
}:
let
  ndhContext = ndh.context;
  catalog = ndhContext.catalog;
  netplan = catalog.netplan or { };
  cfg = config.tailscale;
  tailnet = config.tailnet;
  autoconnectUnitName = ndhSystemd.tailscaleAutoconnectUnitName;
  secretDeps = [ "sops-install-secrets.service" ];
  tagsString = lib.concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags);
  # Only enable regular Tailscale if Headscale module is not enabled.
  useHeadscale = config.networking.headscale.enable or false;
  tailnetDomain =
    if netplan ? tailnet && (netplan.tailnet ? domain) then netplan.tailnet.domain else "";
  tailscaleHostName =
    let
      base = config.networking.hostName;
    in
    if tailnetDomain != "" then "${base}${tailnetDomain}" else base;
in
{
  options.tailscale = {
    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nixos" ];
      description = "Tags to use for the Tailscale node, defaults to ['nixos'].";
    };
  };

  config = lib.mkMerge [
    # Auth-backend-agnostic tailscaled hardening — applies whenever the
    # daemon is enabled, regardless of whether auth is provided by SaaS
    # tailscale or self-hosted headscale.
    (lib.mkIf config.services.tailscale.enable {
      # Force tailscaled to drive netfilter via the native nftables runner
      # instead of shelling out to `iptables` (which on nft-enabled hosts is
      # the iptables-nft compat shim).  The shim in iptables 1.8.13 does not
      # accept tailscale's `--nfmask` extension and fails with
      # "Extension MARK revision 0 not supported, missing kernel module?",
      # which keeps the daemon's netfilter health check red even when
      # peer-to-peer connectivity is up.  Native nftables avoids the shim.
      systemd.services.tailscaled.environment.TS_DEBUG_FIREWALL_MODE = "nftables";

      # Trust Tailscale interface (bypass firewall)
      networking.firewall.trustedInterfaces = [ "tailscale0" ];
    })

    # SaaS tailscale auth path — only when headscale is NOT managing the
    # node.  Headscale ships its own auth wiring in headscale-daemon.nix.
    (lib.mkIf (!useHeadscale) {
      # Opt into the shared tailnet-secret schema.  `tailscaled` is
      # root-run on NixOS, so override the common module's default
      # (profile user) and hand the auth file to root at 0400.
      tailnet.tailscale.auth = {
        enable = true;
        owner = "root";
        mode = "0400";
      };

      services.tailscale = {
        enable = true;
        authKeyFile = tailnet.tailscale.auth.path;
        useRoutingFeatures = "both";
        extraUpFlags = [
          "--ssh"
          "--advertise-tags=${tagsString}"
          "--hostname=${tailscaleHostName}"
        ];
      };

      # Harden canonical autoconnect unit ordering and secret gating.
      systemd.services.${autoconnectUnitName} = {
        wants = lib.mkAfter secretDeps;
        requires = lib.mkAfter secretDeps;
        after = lib.mkAfter secretDeps;
        unitConfig.ConditionPathExists = lib.mkForce tailnet.tailscale.auth.path;
      };
    })
  ];
}
