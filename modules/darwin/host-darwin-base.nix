# Common Darwin host base: the mechanical blocks shared by the operator seats
# (bioskop, nikopol) — retired headscale bootstrap role, tailscale OAuth
# client materialisation + mirror, LLM gateway, host-builder steady state.
#
# Host-specific concerns (tart VM sizing, fabric link, ddns, keyring, ...)
# stay in the per-host darwin.nix.
{
  config,
  lib,
  ...
}:
with lib;

let
  cfg = config.ndh.hostDarwinBase;
in
{
  options.ndh.hostDarwinBase = {
    enable = mkEnableOption "common Darwin host base";

    enableTailscaleClientMirror = mkOption {
      type = types.bool;
      default = true;
      description = "Materialise + mirror the long-lived Tailscale OAuth client.";
    };

    enableLlmGateway = mkOption {
      type = types.bool;
      default = true;
      description = "Enable the Darwin LLM gateway (llama-swap).";
    };

    sopsEncryptedFile = mkOption {
      type = types.path;
      default = ../../.secrets;
      description = "sops-encrypted secrets file for the LLM gateway.";
    };

    hostBuilder = mkOption {
      type = types.nullOr types.str;
      default = "steady";
      description = "ndh.hostBuilder value (null disables).";
    };
  };

  config = mkIf cfg.enable {
    services.headscaleBootstrap.role = "none";

    tailnet.tailscale.client.enable = cfg.enableTailscaleClientMirror;

    ndh.userSecretMirror = lib.optionalAttrs cfg.enableTailscaleClientMirror {
      "tailnet.tailscale.client" = {
        source = config.sops.secrets."tailnet.tailscale.client".path;
        target = "${config.profile.user.home}/.local/share/ndh/tailnet.tailscale.client";
      };
    };

    services.llmGateway = lib.mkIf cfg.enableLlmGateway {
      enable = true;
      sopsEncryptedFile = cfg.sopsEncryptedFile;
    };

    ndh.hostBuilder = lib.mkIf (cfg.hostBuilder != null) cfg.hostBuilder;
  };
}
