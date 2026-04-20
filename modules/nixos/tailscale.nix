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
  autoconnectUnitName = ndhSystemd.tailscaleAutoconnectUnitName;
  tailscaleAuthSecretName = "tailscale.authKey";
  tailscaleAuthSecretCanonicalPath = "/run/secrets/${tailscaleAuthSecretName}";
  tailscaleAuthKeyPath = config.sops.secrets.${tailscaleAuthSecretName}.path;
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
  config = lib.mkIf (!useHeadscale) {
    sops.secrets.${tailscaleAuthSecretName} = {
      format = "yaml";
      key = cfg.authKeySopsKey;
      # Canonical sops-nix path: avoid alias/symlink indirection under /run/secrets.
      path = tailscaleAuthSecretCanonicalPath;
    };

    services.tailscale = {
      enable = true;
      authKeyFile = tailscaleAuthKeyPath;
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
      unitConfig.ConditionPathExists = lib.mkForce tailscaleAuthKeyPath;
    };
  };
  options.tailscale = {
    authKeySopsKey = lib.mkOption {
      type = lib.types.str;
      default = "tailscale/key";
      description = "Key path in .secrets used for the Tailscale auth key.";
    };

    tags = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "nixos" ];
      description = "Tags to use for the Tailscale node, defaults to ['nixos'].";
    };
  };
}
