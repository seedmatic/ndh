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

  config = lib.mkIf (!useHeadscale) {
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

    # Trust Tailscale interface (bypass firewall)
    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    # Harden canonical autoconnect unit ordering and secret gating.
    systemd.services.${autoconnectUnitName} = {
      wants = lib.mkAfter secretDeps;
      requires = lib.mkAfter secretDeps;
      after = lib.mkAfter secretDeps;
      unitConfig.ConditionPathExists = lib.mkForce tailnet.tailscale.auth.path;
    };
  };
}
