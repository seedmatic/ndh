{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.headscale-gateway;
in {
  options.services.headscale-gateway = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Headscale subnet router/gateway";
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

    routes = mkOption {
      type = types.listOf types.str;
      default = [];
      example = [ "192.168.1.0/24" "10.0.0.0/24" ];
      description = "Subnet routes to advertise";
    };

    exitNode = mkOption {
      type = types.bool;
      default = false;
      description = "Advertise as an exit node";
    };

    acceptRoutes = mkOption {
      type = types.bool;
      default = true;
      description = "Accept routes from other nodes";
    };

    snat = mkOption {
      type = types.bool;
      default = true;
      description = "Enable source NAT for subnet routes";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [ "gateway" ];
      description = "Tags to apply to this node";
    };
  };

  config = mkIf cfg.enable {
    # Install Tailscale (client compatible with Headscale)
    services.tailscale = {
      enable = true;
      useRoutingFeatures = "both";  # Enable IP forwarding and routing
      authKeyFile = cfg.authKeyFile;
      extraUpFlags = let
        routeFlags = if (cfg.routes != []) 
          then [ "--advertise-routes=${concatStringsSep "," cfg.routes}" ]
          else [];
        exitNodeFlag = if cfg.exitNode then [ "--advertise-exit-node" ] else [];
        acceptRoutesFlag = if cfg.acceptRoutes then [ "--accept-routes" ] else [];
        snatFlag = if cfg.snat then [ "--snat-subnet-routes=true" ] else [ "--snat-subnet-routes=false" ];
        tagFlags = if (cfg.tags != [])
          then [ "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}" ]
          else [];
      in
        [
          "--login-server=${cfg.serverUrl}"
          "--hostname=${cfg.hostname}"
          "--ssh"
        ] ++ routeFlags ++ exitNodeFlag ++ acceptRoutesFlag ++ snatFlag ++ tagFlags;
    };

    # Enable IP forwarding (required for routing)
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    # Firewall configuration
    networking.firewall = {
      enable = true;
      trustedInterfaces = [ "tailscale0" ];
      
      # Allow forwarding from tailscale interface
      extraCommands = ''
        # Allow forwarding for Tailscale subnet routing
        iptables -A FORWARD -i tailscale0 -j ACCEPT
        iptables -A FORWARD -o tailscale0 -j ACCEPT
        
        # NAT for advertised routes (if SNAT is enabled)
        ${optionalString cfg.snat ''
          ${concatMapStringsSep "\n" (route: ''
            iptables -t nat -A POSTROUTING -s ${route} ! -o tailscale0 -j MASQUERADE
          '') cfg.routes}
        ''}
      '';
      
      extraStopCommands = ''
        iptables -D FORWARD -i tailscale0 -j ACCEPT 2>/dev/null || true
        iptables -D FORWARD -o tailscale0 -j ACCEPT 2>/dev/null || true
        
        ${optionalString cfg.snat ''
          ${concatMapStringsSep "\n" (route: ''
            iptables -t nat -D POSTROUTING -s ${route} ! -o tailscale0 -j MASQUERADE 2>/dev/null || true
          '') cfg.routes}
        ''}
      '';
    };

    # Monitoring and management tools
    environment.systemPackages = with pkgs; [
      tailscale
      (writeScriptBin "headscale-gateway-status" ''
        #!/usr/bin/env bash
        echo "=== Tailscale Status ==="
        ${pkgs.tailscale}/bin/tailscale status
        echo ""
        echo "=== Advertised Routes ==="
        ${pkgs.tailscale}/bin/tailscale status --json | ${pkgs.jq}/bin/jq -r '.Self.AllowedIPs[]'
        echo ""
        echo "=== IP Forwarding Status ==="
        echo "IPv4: $(sysctl -n net.ipv4.ip_forward)"
        echo "IPv6: $(sysctl -n net.ipv6.conf.all.forwarding)"
      '')
    ];

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
        
        ${optionalString (cfg.authKeyFile != null) ''
          # Connect if we have an auth key
          if [ -f "${cfg.authKeyFile}" ]; then
            ${pkgs.tailscale}/bin/tailscale up \
              --login-server=${cfg.serverUrl} \
              --authkey="$(cat ${cfg.authKeyFile})" \
              ${concatStringsSep " " (
                [ "--hostname=${cfg.hostname}" "--ssh" ]
                ++ (if (cfg.routes != []) then [ "--advertise-routes=${concatStringsSep "," cfg.routes}" ] else [])
                ++ (if cfg.exitNode then [ "--advertise-exit-node" ] else [])
                ++ (if cfg.acceptRoutes then [ "--accept-routes" ] else [])
                ++ (if cfg.snat then [ "--snat-subnet-routes=true" ] else [])
                ++ (if (cfg.tags != []) then [ "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}" ] else [])
              )}
          fi
        ''}
      '';
    };
  };
}
