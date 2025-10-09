{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.incus-tailscale-gateway;
in {
  options.services.incus-tailscale-gateway = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Tailscale gateway in Incus container";
    };

    instanceName = mkOption {
      type = types.str;
      default = "tailscale-gateway";
      description = "Name of the Incus instance";
    };

    authKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing Tailscale auth key";
    };

    hostname = mkOption {
      type = types.str;
      default = "${config.networking.hostName}-gateway";
      example = "alcide-gateway";
      description = "Hostname for the gateway";
    };

    routes = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "192.168.5.0/24" "192.168.106.0/24" ];
      description = "Subnet routes to advertise (Lima VM subnets, Incus subnets)";
    };

    exitNode = mkOption {
      type = types.bool;
      default = false;
      description = "Advertise as an exit node";
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
    environment.etc."incus-tailscale-gateway-config.nix" = {
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
              routeFlags = ${if (cfg.routes != []) 
                then ''"--advertise-routes=${concatStringsSep "," cfg.routes}"'' 
                else ''""''};
              exitNodeFlag = ${if cfg.exitNode then ''"--advertise-exit-node"'' else ''""''};
              tagFlags = ${if (cfg.tags != [])
                then ''"--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}"''
                else ''""''};
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
                  --snat-subnet-routes=true \
                  ''${routeFlags:+$routeFlags} \
                  ''${exitNodeFlag:+$exitNodeFlag} \
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
          ];

          system.stateVersion = "24.05";
        }
      '';
    };

    # Deployment script
    environment.systemPackages = [
      (pkgs.writeScriptBin "deploy-tailscale-gateway" ''
        #!/usr/bin/env bash
        set -e

        INSTANCE="${cfg.instanceName}"
        AUTH_KEY_FILE="${cfg.authKeyFile}"

        echo "=== Deploying Tailscale Gateway in Incus ==="

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
        incus file push /etc/incus-tailscale-gateway-config.nix "$INSTANCE"/etc/nixos/configuration.nix

        # Rebuild
        echo "Rebuilding NixOS configuration..."
        incus exec "$INSTANCE" -- nixos-rebuild switch

        # Enable IP forwarding on host
        echo "Enabling IP forwarding..."
        sysctl -w net.ipv4.ip_forward=1
        sysctl -w net.ipv6.conf.all.forwarding=1

        echo ""
        echo "=== Tailscale Gateway Deployed ==="
        echo "Instance: $INSTANCE"
        echo "Check status: incus exec $INSTANCE -- tailscale status"
        echo "Get shell: incus exec $INSTANCE -- bash"
        echo ""
        echo "⚠️  Remember to approve routes in Tailscale admin console:"
        echo "   Routes to approve: ${concatStringsSep ", " cfg.routes}"
      '')
      (pkgs.writeScriptBin "tailscale-gateway-status" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        
        if ! incus list -c n -f csv | grep -q "^$INSTANCE$"; then
          echo "Instance $INSTANCE does not exist"
          echo "Run: deploy-tailscale-gateway"
          exit 1
        fi
        
        echo "=== Tailscale Gateway Status ==="
        incus exec "$INSTANCE" -- tailscale status
        
        echo ""
        echo "=== Instance Info ==="
        incus info "$INSTANCE"
      '')
      (pkgs.writeScriptBin "tailscale-gateway-shell" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        incus exec "$INSTANCE" -- bash
      '')
      (pkgs.writeScriptBin "tailscale-gateway-logs" ''
        #!/usr/bin/env bash
        INSTANCE="${cfg.instanceName}"
        incus exec "$INSTANCE" -- journalctl -u tailscaled -u tailscale-autoconnect -f
      '')
    ];

    # Enable IP forwarding on host
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };
  };
}
