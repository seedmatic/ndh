{
  config,
  pkgs,
  lib,
  catalog,
  ...
}:
let
  networkCatalog = catalog.networks or { };
  cfg = config.tailscale;
  tailscaleAuthSecretName = "tailscale.authKey";
  tailscaleAuthKeyPath = config.sops.secrets.${tailscaleAuthSecretName}.path;
  tagsString = lib.concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags);
  # Only enable regular Tailscale if Headscale module is not enabled.
  useHeadscale = config.services.headscale.enable or false;
  tailnetDomain =
    if networkCatalog ? tailnet && (networkCatalog.tailnet ? domain) then
      networkCatalog.tailnet.domain
    else
      "";
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
      path = "/run/secrets/tailscale/auth.key";
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
    systemd.services.tailscaled-autoconnect = {
      enable = true;
      after = lib.mkAfter [ "network-online.target" ];
      wants = lib.mkAfter [ "network-online.target" ];
      serviceConfig = {
        Restart = "on-failure";
        Type = lib.mkForce "simple";
        # Do not block boot: do not set WantedBy or RequiredBy to multi-user.target
        # Remove Install section so systemd does not wait for this service at boot
      };
      wantedBy = lib.mkForce [ ];
      requiredBy = lib.mkForce [ ];
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