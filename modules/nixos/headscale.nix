{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.networking.headscale;
  defaultHostname = config.networking.hostName;
in
{
  options.networking.headscale = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Headscale client (Tailscale connected to Headscale)";
    };

    serverUrl = mkOption {
      type = types.str;
      example = "https://headscale.example.com";
      description = "URL of the Headscale server";
    };

    authKeyFile = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Path to file containing the Headscale auth key";
    };

    hostname = mkOption {
      type = types.str;
      default = defaultHostname;
      description = "Hostname to advertise";
    };

    enableSSH = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Tailscale SSH";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "server"
        "production"
      ];
      description = "Tags to apply to this node";
    };

    acceptRoutes = mkOption {
      type = types.bool;
      default = false;
      description = "Accept routes from other nodes (useful if you have gateways)";
    };
  };

  config = mkIf cfg.enable {
    # Install Tailscale (client compatible with Headscale)
    services.tailscale = {
      enable = true;
      authKeyFile = cfg.authKeyFile;
      extraUpFlags =
        let
          sshFlag = if cfg.enableSSH then [ "--ssh" ] else [ ];
          tagFlags =
            if (cfg.tags != [ ]) then
              [ "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}" ]
            else
              [ ];
          acceptRoutesFlag = if cfg.acceptRoutes then [ "--accept-routes" ] else [ ];
        in
        [
          "--login-server=${cfg.serverUrl}"
          "--hostname=${cfg.hostname}"
        ]
        ++ sshFlag
        ++ tagFlags
        ++ acceptRoutesFlag;
    };

    # Trust Tailscale interface
    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    # Ensure Tailscale connects at boot
    systemd.services.ndh-tailscaled-autoconnect = {
      after = [
        "tailscaled.service"
        "network-online.target"
      ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        set -euo pipefail

        wait_for_tailscaled() {
          for i in $(seq 1 30); do
            # "tailscale version" talks to the daemon without requiring login
            if ${pkgs.tailscale}/bin/tailscale version >/dev/null 2>&1; then
              return 0
            fi
            sleep 1
          done
          echo "tailscaled not ready after 30s" >&2
          return 1
        }

        wait_for_tailscaled || exit 0

        # If already connected, we're done
        if ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; then
          echo "Already connected to Headscale"
          exit 0
        fi

        auth_key_file="${if cfg.authKeyFile != null then cfg.authKeyFile else ""}"

        if [ -z "$auth_key_file" ] || [ ! -f "$auth_key_file" ]; then
          echo "No auth key available; skipping autoconnect"
          exit 0
        fi

        ${pkgs.tailscale}/bin/tailscale up \
          --login-server=${cfg.serverUrl} \
          --authkey="$(cat "$auth_key_file")" \
          --hostname=${cfg.hostname} \
          ${optionalString cfg.enableSSH "--ssh"} \
          ${optionalString cfg.acceptRoutes "--accept-routes"} \
          ${
            optionalString (cfg.tags != [ ])
              "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}"
          } || {
            echo "tailscale up failed" >&2
            exit 1
          }

        exit 0
      '';
    };

    # Add useful management commands
    environment.systemPackages = with pkgs; [
      tailscale
      (writeScriptBin "hs-status" ''
        #!/usr/bin/env bash
        echo "=== Headscale Connection Status ==="
        ${pkgs.tailscale}/bin/tailscale status
        echo ""
        echo "=== Network Check ==="
        ${pkgs.tailscale}/bin/tailscale netcheck
      '')
      (writeScriptBin "hs-ssh" ''
        #!/usr/bin/env bash
        if [ -z "$1" ]; then
          echo "Usage: hs-ssh <hostname>"
          echo "Available hosts:"
          ${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -r '.Peer[].HostName'
          exit 1
        fi
        ${pkgs.tailscale}/bin/tailscale ssh "$1"
      '')
    ];
  };
}