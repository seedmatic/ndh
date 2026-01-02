{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.incus-headscale-gateway;
in
{
  options.services.incus-headscale-gateway = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Deploy Headscale gateway (Tailscale bridge) as Incus container";
    };

    instanceName = mkOption {
      type = types.str;
      default = "headscale-gateway";
      description = "Name of the Incus instance";
    };

    hostname = mkOption {
      type = types.str;
      default = "${config.networking.hostName}-hs-gateway";
      example = "bioskop-hs-gateway";
      description = "Hostname for the gateway";
    };

    tailscaleAuthKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing Tailscale auth key";
    };

    advertiseRoutes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "100.64.0.0/10"
        "192.168.1.0/24"
        "192.168.5.0/24"
      ];
      description = "Routes to advertise to Tailscale (typically Headscale network + local networks)";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [ "gateway" ];
      description = "Tailscale tags";
    };

    profile = mkOption {
      type = types.str;
      default = "default";
      description = "Incus profile to use";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Incus is enabled
    virtualisation.incus.enable = true;

    # Create NixOS configuration for the gateway
    environment.etc."incus-headscale-gateway-config.nix" = {
      text = ''
        { config, pkgs, ... }:
        {
          networking = {
            hostName = "${cfg.hostname}";
            useHostResolvConf = false;
            nameservers = [ "1.1.1.1" "1.0.0.1" ];
            firewall.enable = false;
          };

          boot.kernel.sysctl = {
            "net.ipv4.ip_forward" = 1;
            "net.ipv6.conf.all.forwarding" = 1;
          };

          services.tailscale = {
            enable = true;
            useRoutingFeatures = "both";
          };

          systemd.tmpfiles.rules = [
            "d /run/tailscale 0755 root root -"
          ];

          systemd.services.tailscale-autoconnect = {
            after = [ "tailscaled.service" "network-online.target" ];
            wants = [ "network-online.target" ];
            wantedBy = [ "multi-user.target" ];
            serviceConfig = {
              Type = "oneshot";
              RemainAfterExit = true;
            };
            script = let
              routeFlags = ${
                if (cfg.advertiseRoutes != [ ]) then
                  ''"--advertise-routes=${concatStringsSep "," cfg.advertiseRoutes}"''
                else
                  ''""''
              };
              tagFlags = ${
                if (cfg.tags != [ ]) then
                  ''"--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}"''
                else
                  ''""''
              };
            in '''
              sleep 2
              
              if ''${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; then
                exit 0
              fi
              
              if [ -f "/run/tailscale/auth.key" ]; then
                ''${pkgs.tailscale}/bin/tailscale up \
                  --authkey="$(cat /run/tailscale/auth.key)" \
                  --hostname=${cfg.hostname} \
                  --ssh \
                  --accept-routes \
                  --accept-dns=false \
                  --snat-subnet-routes=true \
                  ''${routeFlags:+$routeFlags} \
                  ''${tagFlags:+$tagFlags}
              fi
            ''';
          };

          environment.systemPackages = with pkgs; [
            tailscale
            iptables
            traceroute
            tcpdump
            curl
            dig
          ];

          system.stateVersion = "24.05";
        }
      '';
    };

    # Deployment script
    environment.systemPackages = [
      (pkgs.writeScriptBin "deploy-headscale-gateway" ''
        #!/usr/bin/env bash
        set -e

        INSTANCE="${cfg.instanceName}"
        AUTH_KEY_FILE="${cfg.tailscaleAuthKeyFile}"

        echo "=== Deploying Headscale Gateway (Tailscale Bridge) in Incus ==="

        # Check if instance exists
        if incus list -c n -f csv | grep -q "^$INSTANCE$"; then
          echo "Instance $INSTANCE already exists"
        else
          echo "Creating instance $INSTANCE..."
          incus launch images:nixos/unstable "$INSTANCE" --profile ${cfg.profile}
          sleep 5
        fi

        # Wait for instance to be ready
        echo "Waiting for instance to be ready..."
        for i in {1..30}; do
          if incus exec "$INSTANCE" -- systemctl is-system-running --wait 2>/dev/null | grep -qE "running|degraded"; then
            break
          fi
          sleep 2
        done

        # Copy auth key
        echo "Copying Tailscale auth key..."
        incus exec "$INSTANCE" -- mkdir -p /run/tailscale
        cat "$AUTH_KEY_FILE" | incus exec "$INSTANCE" -- tee /run/tailscale/auth.key > /dev/null
        incus exec "$INSTANCE" -- chmod 600 /run/tailscale/auth.key

        # Copy configuration
        echo "Copying NixOS configuration..."
        incus file push /etc/incus-headscale-gateway-config.nix "$INSTANCE"/etc/nixos/configuration.nix

        # Rebuild
        echo "Rebuilding NixOS configuration..."
        incus exec "$INSTANCE" -- nixos-rebuild switch

        # Enable IP forwarding on host
        echo "Enabling IP forwarding..."
        sysctl -w net.ipv4.ip_forward=1
        sysctl -w net.ipv6.conf.all.forwarding=1

        echo ""
        echo "=== Headscale Gateway Deployed ==="
        echo "Instance: $INSTANCE"
        echo "Hostname: ${cfg.hostname}"
        echo "Advertised routes: ${concatStringsSep ", " cfg.advertiseRoutes}"
        echo ""
        echo "Check status: headscale-gateway-status"
        echo ""
        echo "⚠️  Remember to:"
        echo "   1. Approve routes in Tailscale admin console"
        echo "   2. Ensure Headscale network (100.64.0.0/10) is accessible from this gateway"
      '')
      (pkgs.writeScriptBin "headscale-gateway-status" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"

        if ! incus list -c n -f csv | grep -q "^$INSTANCE$"; then
          echo "Instance $INSTANCE does not exist"
          echo "Run: deploy-headscale-gateway"
          exit 1
        fi

        echo "=== Headscale Gateway Status ==="
        incus exec "$INSTANCE" -- tailscale status

        echo ""
        echo "=== Advertised Routes ==="
        incus exec "$INSTANCE" -- tailscale status --json | incus exec "$INSTANCE" -- jq -r '.Self.AllowedIPs[]'

        echo ""
        echo "=== Instance Info ==="
        incus info "$INSTANCE"
      '')
      (pkgs.writeScriptBin "headscale-gateway-shell" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        incus exec "$INSTANCE" -- bash
      '')
      (pkgs.writeScriptBin "headscale-gateway-logs" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        incus exec "$INSTANCE" -- journalctl -u tailscaled -u tailscale-autoconnect -f
      '')
      (pkgs.writeScriptBin "headscale-gateway-restart" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        echo "Restarting Tailscale in gateway..."
        incus exec "$INSTANCE" -- systemctl restart tailscaled tailscale-autoconnect
        sleep 2
        headscale-gateway-status
      '')
    ];

    # Enable IP forwarding on host
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
  };
}
