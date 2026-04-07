{
  config,
  pkgs,
  lib,
  ...
}:

with lib;

let
  cfg = config.containers.tailscale-gateway;
in
{
  options.containers.tailscale-gateway = {
    enable = mkOption {
      type = types.bool;
      default = false;
      description = "Enable Tailscale gateway container";
    };

    authKeyFile = mkOption {
      type = types.path;
      description = "Path to file containing Tailscale auth key";
    };

    hostname = mkOption {
      type = types.str;
      default = "${config.networking.hostName}-gateway";
      example = "nikopol-gateway";
      description = "Hostname for the gateway";
    };

    routes = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "192.168.5.0/24"
        "192.168.106.0/24"
      ];
      description = "Subnet routes to advertise";
    };

    exitNode = mkOption {
      type = types.bool;
      default = false;
      description = "Advertise as an exit node";
    };

    hostAddress = mkOption {
      type = types.str;
      default = "192.168.100.10";
      description = "Host-side IP address for the container";
    };

    localAddress = mkOption {
      type = types.str;
      default = "192.168.100.11";
      description = "Container IP address";
    };

    tags = mkOption {
      type = types.listOf types.str;
      default = [ "gateway" ];
      description = "Tailscale tags";
    };
  };

  config = mkIf cfg.enable {
    # Create the Tailscale gateway container
    containers.tailscale-gateway = {
      autoStart = true;
      privateNetwork = true;
      hostAddress = cfg.hostAddress;
      localAddress = cfg.localAddress;

      # Allow container to forward packets
      enableTun = true;

      config =
        { config, pkgs, ... }:
        {
          # Enable networking
          networking = {
            hostName = cfg.hostname;
            useHostResolvConf = false;
            nameservers = [
              "1.1.1.1"
              "1.0.0.1"
            ];
            firewall.enable = false; # Tailscale handles this
          };

          # Enable IP forwarding
          boot.kernel.sysctl = {
            "net.ipv4.ip_forward" = 1;
            "net.ipv6.conf.all.forwarding" = 1;
          };

          # Tailscale service
          services.tailscale = {
            enable = true;
            useRoutingFeatures = "both";
            extraUpFlags =
              let
                routeFlags =
                  if (cfg.routes != [ ]) then [ "--advertise-routes=${concatStringsSep "," cfg.routes}" ] else [ ];
                exitNodeFlag = if cfg.exitNode then [ "--advertise-exit-node" ] else [ ];
                tagFlags =
                  if (cfg.tags != [ ]) then
                    [ "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}" ]
                  else
                    [ ];
              in
              [
                "--hostname=${cfg.hostname}"
                "--ssh"
                "--accept-routes"
                "--snat-subnet-routes=true"
              ]
              ++ routeFlags
              ++ exitNodeFlag
              ++ tagFlags;
          };

          # Copy auth key from host
          systemd.tmpfiles.rules = [
            "L+ /run/tailscale/auth.key - - - - ${cfg.authKeyFile}"
          ];

          # Auto-connect service
          systemd.services.ndh-tailscale-autoconnect = {
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
              sleep 2

              if ${pkgs.tailscale}/bin/tailscale status >/dev/null 2>&1; then
                echo "Already connected to Tailscale"
                exit 0
              fi

              if [ -f "/run/tailscale/auth.key" ]; then
                ${pkgs.tailscale}/bin/tailscale up \
                  --authkey="$(cat /run/tailscale/auth.key)" \
                  --hostname=${cfg.hostname} \
                  --ssh \
                  --accept-routes \
                  --snat-subnet-routes=true \
                  ${optionalString (cfg.routes != [ ]) "--advertise-routes=${concatStringsSep "," cfg.routes}"} \
                  ${optionalString cfg.exitNode "--advertise-exit-node"} \
                  ${optionalString (cfg.tags != [ ])
                    "--advertise-tags=${concatStringsSep "," (map (tag: "tag:" + tag) cfg.tags)}"
                  }
              fi
            '';
          };

          # Monitoring tools
          environment.systemPackages = with pkgs; [
            tailscale
            iptables
            traceroute
            tcpdump
          ];

          system.stateVersion = "24.05";
        };
    };

    # NAT configuration for the container
    networking.nat = {
      enable = true;
      internalInterfaces = [ "ve-tailscale-gateway" ];
      externalInterface = mkDefault "eth0";

      # Forward all traffic from container
      forwardPorts = [ ];
    };

    # Allow forwarding
    boot.kernel.sysctl = {
      "net.ipv4.ip_forward" = 1;
      "net.ipv6.conf.all.forwarding" = 1;
    };

    # Firewall rules to allow container traffic
    networking.firewall = {
      trustedInterfaces = [ "ve-tailscale-gateway" ];
      extraCommands = ''
        # Allow forwarding from/to container
        iptables -A FORWARD -i ve-tailscale-gateway -j ACCEPT
        iptables -A FORWARD -o ve-tailscale-gateway -j ACCEPT
      '';
    };

    # Create management script
    environment.systemPackages = [
      (pkgs.writeScriptBin "tailscale-gateway-status" ''
        #!/usr/bin/env bash
        echo "=== Tailscale Gateway Status ==="
        nixos-container run tailscale-gateway -- tailscale status
        echo ""
        echo "=== Advertised Routes ==="
        nixos-container run tailscale-gateway -- tailscale status --json | ${pkgs.jq}/bin/jq -r '.Self.AllowedIPs[]'
      '')
      (pkgs.writeScriptBin "tailscale-gateway-shell" ''
        #!/usr/bin/env bash
        nixos-container root-login tailscale-gateway
      '')
    ];
  };
}
