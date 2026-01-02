{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.services.incus-headscale-server;
in
{
  options.services.incus-headscale-server = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Deploy Headscale server as Incus container";
    };

    instanceName = mkOption {
      type = types.str;
      default = "headscale-server";
      description = "Name of the Incus instance";
    };

    serverUrl = mkOption {
      type = types.str;
      example = "http://192.168.5.10:8080";
      description = "Public URL for Headscale server";
    };

    baseDomain = mkOption {
      type = types.str;
      default = "home.arpa";
      description = "Base domain for MagicDNS (default uses the reserved .home.arpa suffix)";
    };

    listenAddr = mkOption {
      type = types.str;
      default = "0.0.0.0:8080";
      description = "Address to listen on";
    };

    profile = mkOption {
      type = types.str;
      default = "default";
      description = "Incus profile to use";
    };

    ipAddress = mkOption {
      type = types.nullOr types.str;
      default = null;
      example = "192.168.5.10";
      description = "Static IP address for the container (optional)";
    };
  };

  config = mkIf cfg.enable {
    # Ensure Incus is enabled
    virtualisation.incus.enable = true;

    # Create NixOS configuration for the Headscale server
    environment.etc."incus-headscale-server-config.nix" = {
      text = ''
        { config, pkgs, ... }:
        {
          networking = {
            hostName = "${cfg.instanceName}";
            useHostResolvConf = false;
            nameservers = [ "1.1.1.1" "1.0.0.1" ];
            firewall = {
              enable = true;
              allowedTCPPorts = [ 8080 50443 ];  # HTTP and gRPC
            };
          };

          services.headscale = {
            enable = true;
            address = "${cfg.listenAddr}";
            
            settings = {
              server_url = "${cfg.serverUrl}";
              listen_addr = "${cfg.listenAddr}";
              metrics_listen_addr = "127.0.0.1:9090";
              
              grpc_listen_addr = "127.0.0.1:50443";
              grpc_allow_insecure = false;
              
              database = {
                type = "sqlite3";
                sqlite = {
                  path = "/var/lib/headscale/db.sqlite";
                };
              };
              
              ip_prefixes = [
                "100.64.0.0/10"
              ];
              
              dns_config = {
                override_local_dns = true;
                base_domain = "${cfg.baseDomain}";
                magic_dns = true;
                nameservers = [ "1.1.1.1" "1.0.0.1" ];
                domains = [];
              };
              
              derp = {
                server = {
                  enabled = false;
                };
                urls = [ "https://controlplane.tailscale.com/derpmap/default" ];
                auto_update_enabled = true;
                update_frequency = "24h";
              };
              
              disable_check_updates = true;
              
              policy = {
                path = "/etc/headscale/policy.json";
              };
            };
          };

          environment.etc."headscale/policy.json" = {
            text = builtins.toJSON {
              acls = [
                {
                  action = "accept";
                  src = [ "*" ];
                  dst = [ "*:*" ];
                }
              ];
              
              groups = {
                "group:admin" = [];
                "group:servers" = [];
                "group:clients" = [];
                "group:gateways" = [];
              };
              
              tagOwners = {
                "tag:server" = [ "group:admin" ];
                "tag:client" = [ "group:admin" ];
                "tag:gateway" = [ "group:admin" ];
              };
            };
          };

          systemd.tmpfiles.rules = [
            "d /var/lib/headscale 0755 headscale headscale -"
          ];

          environment.systemPackages = with pkgs; [
            headscale
            curl
            jq
          ];

          system.stateVersion = "24.05";
        }
      '';
    };

    # Deployment script
    environment.systemPackages = [
      (pkgs.writeScriptBin "deploy-headscale-server" ''
        #!/usr/bin/env bash
        set -e

        INSTANCE="${cfg.instanceName}"

        echo "=== Deploying Headscale Server in Incus ==="

        # Check if instance exists
        if incus list -c n -f csv | grep -q "^$INSTANCE$"; then
          echo "Instance $INSTANCE already exists"
        else
          echo "Creating instance $INSTANCE..."
          incus launch images:nixos/unstable "$INSTANCE" --profile ${cfg.profile}
          
          ${optionalString (cfg.ipAddress != null) ''
            echo "Setting static IP address..."
            incus config device override "$INSTANCE" eth0 ipv4.address="${cfg.ipAddress}"
          ''}
          
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

        # Copy configuration
        echo "Copying NixOS configuration..."
        incus file push /etc/incus-headscale-server-config.nix "$INSTANCE"/etc/nixos/configuration.nix

        # Rebuild
        echo "Rebuilding NixOS configuration..."
        incus exec "$INSTANCE" -- nixos-rebuild switch

        echo ""
        echo "=== Headscale Server Deployed ==="
        echo "Instance: $INSTANCE"
        echo "Server URL: ${cfg.serverUrl}"
        echo ""
        echo "Next steps:"
        echo "1. Create a user:"
        echo "   incus exec $INSTANCE -- headscale users create <username>"
        echo ""
        echo "2. Create a pre-auth key:"
        echo "   incus exec $INSTANCE -- headscale preauthkeys create --user <username> --reusable --expiration 24h"
        echo ""
        echo "3. Check server status:"
        echo "   headscale-server-status"
      '')
      (pkgs.writeScriptBin "headscale-server-status" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"

        if ! incus list -c n -f csv | grep -q "^$INSTANCE$"; then
          echo "Instance $INSTANCE does not exist"
          echo "Run: deploy-headscale-server"
          exit 1
        fi

        echo "=== Headscale Server Status ==="
        echo "Instance: $INSTANCE"
        echo "URL: ${cfg.serverUrl}"
        echo ""

        echo "=== Registered Nodes ==="
        incus exec "$INSTANCE" -- headscale nodes list

        echo ""
        echo "=== Users ==="
        incus exec "$INSTANCE" -- headscale users list

        echo ""
        echo "=== Routes ==="
        incus exec "$INSTANCE" -- headscale routes list
      '')
      (pkgs.writeScriptBin "headscale-server-shell" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        incus exec "$INSTANCE" -- bash
      '')
      (pkgs.writeScriptBin "headscale-create-user" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        if [ -z "$1" ]; then
          echo "Usage: headscale-create-user <username>"
          exit 1
        fi
        incus exec "$INSTANCE" -- headscale users create "$1"
      '')
      (pkgs.writeScriptBin "headscale-create-authkey" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        if [ -z "$1" ]; then
          echo "Usage: headscale-create-authkey <username> [--reusable] [--ephemeral]"
          exit 1
        fi
        incus exec "$INSTANCE" -- headscale preauthkeys create --user "$1" "''${@:2}"
      '')
      (pkgs.writeScriptBin "headscale-approve-routes" ''
        #!/usr:env bash
        INSTANCE="${cfg.instanceName}"
        if [ -z "$1" ] || [ -z "$2" ]; then
          echo "Usage: headscale-approve-routes <node-id> <routes>"
          echo "Example: headscale-approve-routes 1 192.168.1.0/24"
          exit 1
        fi
        incus exec "$INSTANCE" -- headscale routes enable --route "$2" "$1"
      '')
    ];
  };
}
