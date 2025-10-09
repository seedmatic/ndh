{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.headscale-client;
in {
  options.services.headscale-client = {
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
      default = config.networking.hostName;
      description = "Hostname to advertise";
    };

    enableSSH = mkOption {
      type = types.bool;
      default = true;
      description = "Enable Tailscale SSH";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "server" "production" ];
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
      extraUpFlags = let
        sshFlag = if cfg.enableSSH then [ "--ssh" ] else [];
        tagFlags = if (cfg.tags != [])
          then [ "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}" ]
          else [];
        acceptRoutesFlag = if cfg.acceptRoutes then [ "--accept-routes" ] else [];
      in
        [
          "--login-server=${cfg.serverUrl}"
          "--hostname=${cfg.hostname}"
        ] ++ sshFlag ++ tagFlags ++ acceptRoutesFlag;
    };

    # Trust Tailscale interface
    networking.firewall.trustedInterfaces = [ "tailscale0" ];

    # Ensure Tailscale connects at boot
    systemd.services.tailscaled-autoconnect = {
      after = [ "tailscaled.service" "network-online.target" ];
      wants = [ "network-online.target" ];
      wantedBy = [ "multi-user.target" ];
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
      };
      script = ''
        # Wait for tailscaled to be ready
        sleep 2
        
        # Check if already connected
        if ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; then
          echo "Already connected to Headscale"
          exit 0
        fi
        
        # Connect if we have an auth key
        if [ -f "${cfg.authKeyFile}" ]; then
          ${pkgs.tailscale}/bin/tailscale up \
            --login-server=${cfg.serverUrl} \
            --authkey="$(cat ${cfg.authKeyFile})" \
            --hostname=${cfg.hostname} \
            ${optionalString cfg.enableSSH "--ssh"} \
            ${optionalString cfg.acceptRoutes "--accept-routes"} \
            ${optionalString (cfg.tags != []) "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}"}
        fi
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
