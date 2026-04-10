{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.incusRemoteTrust;
  hostProfile = config.profile.host;
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  remoteHostDefault = "${effectiveHostName}-nixos.local";
  userHome = config.profile.user.home;

  incusRemoteTrustActivationScript = pkgs.runCommand "incus-remote-trust-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./incus-remote-trust.d/post-activation.sh {
        logger = lib.attrByPath [
          "activation"
          "loggerScript"
        ] ../common/shell.d/logger.sh config;
        remoteHost = cfg.remoteHost;
        localClientCert = cfg.localClientCert;
        trustEntryName = cfg.trustEntryName;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  options.services.incusRemoteTrust = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Ensure the local macOS Incus client certificate is trusted by the remote NixOS Incus host.";
    };

    remoteHost = mkOption {
      type = types.str;
      default = remoteHostDefault;
      description = "SSH host used to reach the NixOS Incus daemon host.";
    };

    localClientCert = mkOption {
      type = types.str;
      default = "${userHome}/.config/incus/client.crt";
      description = "Path to the local Incus client certificate to trust remotely.";
    };

    trustEntryName = mkOption {
      type = types.str;
      default = "macos-incus-client";
      description = "Name used for the remote Incus trust entry.";
    };
  };

  config = mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    system.activationScripts.postActivation.text = mkAfter ''
      ${incusRemoteTrustActivationScript}
    '';
  };
}
