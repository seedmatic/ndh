{
  config,
  pkgs,
  lib,
  ndh,
  ...
}:

with lib;

let
  cfg = config.services.incusRemoteTrust;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  hostProfile = config.profile.host;
  effectiveHostName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;

  # The ONE name form for an infra host, served by that host's own dnsmasq in its `.<host>` zone and
  # reachable over the tailnet split-DNS.  It used to be `<host>-nixos.local`: mDNS, which answers
  # only while the operator shares an L2 with the guest and dies across a routed boundary — the trap
  # already documented for `.lan` in the netplan atlas.
  remoteHostDefault = "nixos.${effectiveHostName}";
  userHome = config.profile.user.home;

  incusRemoteTrustActivationScript =
    ndh.store.runCommand "incus-remote-trust-post-activation.sh" { }
      ''
        cp ${
          pkgs.replaceVars ./incus-remote-trust.d/post-activation.sh {
            nixBashTrampoline = nixBashTrampoline;
            remoteHost = cfg.remoteHost;
            localClientCert = cfg.localClientCert;
            trustEntryName = cfg.trustEntryName;
            serverCertPin = cfg.serverCertPin;
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

    serverCertPin = mkOption {
      type = types.str;
      default = "${userHome}/.config/incus/servercerts/${effectiveHostName}-nixos.crt";
      description = ''
        Where the local Incus client pins the REMOTE daemon's server certificate. Keyed by the
        client's remote NAME (`<host>-nixos`), which is a client-config fact and deliberately not the
        ssh target above — one is an identity, the other an address.

        Reconciled at every activation because a Tart factory reset recreates the guest's
        /var/lib/incus, so the daemon returns with a new certificate while this file still pins the
        old one. Set to "" to leave the pin alone.
      '';
    };
  };

  config = mkIf (pkgs.stdenv.isDarwin && cfg.enable) {
    system.activationScripts.postActivation.text = mkAfter ''
      ${incusRemoteTrustActivationScript}
    '';
  };
}
