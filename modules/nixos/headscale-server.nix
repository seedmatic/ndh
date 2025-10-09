{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.headscale-custom;
in {
  options.services.headscale-custom = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Headscale control server";
    };

    serverUrl = mkOption {
      type = types.str;
      example = "https://headscale.example.com";
      description = "Public URL of the Headscale server";
    };

    listenAddr = mkOption {
      type = types.str;
      default = "0.0.0.0:8080";
      description = "Address to listen on";
    };

    metricsListenAddr = mkOption {
      type = types.str;
      default = "127.0.0.1:9090";
      description = "Metrics endpoint address";
    };

    baseDomain = mkOption {
      type = types.str;
      default = "mammoth-skate.local";
      description = "Base domain for MagicDNS";
    };

    derp = {
      urls = mkOption {
        type = types.listOf types.str;
        default = [ "https://controlplane.tailscale.com/derpmap/default" ];
        description = "DERP server URLs";
      };

      autoUpdate = mkOption {
        type = types.bool;
        default = true;
        description = "Auto-update DERP map";
      };
    };

    oidc = {
      enable = mkOption {
        type = types.bool;
        default = false;
        description = "Enable OIDC authentication";
      };

      issuer = mkOption {
        type = types.str;
        default = "";
        description = "OIDC issuer URL";
      };

      clientId = mkOption {
        type = types.str;
        default = "";
        description = "OIDC client ID";
      };

      clientSecretFile = mkOption {
        type = types.nullOr types.path;
        default = null;
        description = "Path to file containing OIDC client secret";
      };
    };
  };

  config = mkIf cfg.enable {
    services.headscale = {
      enable = true;
      address = cfg.listenAddr;
      
      settings = {
        server_url = cfg.serverUrl;
        listen_addr = cfg.listenAddr;
        metrics_listen_addr = cfg.metricsListenAddr;
        
        # gRPC settings
        grpc_listen_addr = "127.0.0.1:50443";
        grpc_allow_insecure = false;
        
        # Database
        database = {
          type = "sqlite3";
          sqlite = {
            path = "/var/lib/headscale/db.sqlite";
          };
        };
        
        # Network settings
        ip_prefixes = [
          "100.64.0.0/10"  # Tailscale-compatible range
        ];
        
        # DNS configuration
        dns_config = {
          override_local_dns = true;
          base_domain = cfg.baseDomain;
          magic_dns = true;
          nameservers = [
            "1.1.1.1"
            "1.0.0.1"
          ];
        };
        
        # DERP configuration
        derp = {
          server = {
            enabled = false;  # Don't run embedded DERP
          };
          urls = cfg.derp.urls;
          auto_update_enabled = cfg.derp.autoUpdate;
          update_frequency = "24h";
        };
        
        # Disable telemetry
        disable_check_updates = true;
        
        # ACL policy file
        policy = {
          path = "/etc/headscale/policy.json";
        };
        
        # OIDC configuration
        oidc = mkIf cfg.oidc.enable {
          issuer = cfg.oidc.issuer;
          client_id = cfg.oidc.clientId;
          client_secret_path = cfg.oidc.clientSecretFile;
          scope = [ "openid" "profile" "email" ];
        };
      };
    };

    # Create default ACL policy if it doesn't exist
    environment.etc."headscale/policy.json" = {
      text = builtins.toJSON {
        acls = [
          {
            action = "accept";
            src = [ "*" ];
            dst = [ "*:*" ];
          }
        ];
        
        # Define groups for better access control
        groups = {
          "group:admin" = [];
          "group:servers" = [];
          "group:clients" = [];
        };
        
        # Tag owners
        tagOwners = {
          "tag:server" = [ "group:admin" ];
          "tag:client" = [ "group:admin" ];
          "tag:gateway" = [ "group:admin" ];
        };
      };
    };

    # Open firewall ports
    networking.firewall = {
      allowedTCPPorts = [ 8080 50443 ];  # HTTP/gRPC
      allowedUDPPorts = [ ];
    };

    # Useful management scripts
    environment.systemPackages = [
      pkgs.headscale
      (pkgs.writeScriptBin "headscale-user-add" ''
        #!/usr/bin/env bash
        if [ -z "$1" ]; then
          echo "Usage: headscale-user-add <username>"
          exit 1
        fi
        ${pkgs.headscale}/bin/headscale users create "$1"
      '')
      (pkgs.writeScriptBin "headscale-preauth" ''
        #!/usr/bin/env bash
        if [ -z "$1" ]; then
          echo "Usage: headscale-preauth <username> [--reusable] [--ephemeral]"
          exit 1
        fi
        ${pkgs.headscale}/bin/headscale preauthkeys create --user "$1" "''${@:2}"
      '')
      (pkgs.writeScriptBin "headscale-routes-approve" ''
        #!/usr/bin/env bash
        if [ -z "$1" ]; then
          echo "Usage: headscale-routes-approve <node-id> <routes>"
          echo "Example: headscale-routes-approve 1 192.168.1.0/24"
          exit 1
        fi
        ${pkgs.headscale}/bin/headscale routes enable --route "$2" "$1"
      '')
    ];

    # Ensure the data directory exists
    systemd.tmpfiles.rules = [
      "d /var/lib/headscale 0755 headscale headscale -"
    ];
  };
}
