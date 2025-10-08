{ config, pkgs, lib, ... }:

with lib;

let
  cfg = config.services.teleport-node;
  hostName = config.networking.hostName;
  
  # Get Tailscale hostname
  tailscaleHostname = "${hostName}.mammoth-skate.ts.net";
  
  teleportConfigFile = pkgs.writeText "teleport.yaml" ''
    version: v3
    teleport:
      nodename: ${hostName}
      data_dir: ${cfg.dataDir}
      log:
        output: stderr
        severity: ${cfg.logLevel}
        format:
          output: text
      advertise_ip: ${tailscaleHostname}
      auth_token: ${cfg.authToken}
      auth_servers:
        - ${cfg.authServer}
    
    ssh_service:
      enabled: yes
      labels:
        env: ${cfg.environment}
        role: node
        hostname: ${hostName}
      ${optionalString (cfg.commands != {}) ''
      commands:
      ${concatStringsSep "\n" (mapAttrsToList (name: cmd: "  - name: ${name}\n    command: [${concatMapStringsSep ", " (x: ''"${x}"'') cmd}]\n    period: 1m0s") cfg.commands)}
      ''}
    
    auth_service:
      enabled: no
    
    proxy_service:
      enabled: no
  '';
in
{
  options.services.teleport-node = {
    enable = mkEnableOption "Teleport SSH node";
    
    authServer = mkOption {
      type = types.str;
      example = "bioskop.mammoth-skate.ts.net:3025";
      description = "Teleport auth server address (Tailscale hostname:port)";
    };
    
    authToken = mkOption {
      type = types.str;
      default = "insecure-dev-token-change-me";
      description = ''
        Join token for this node. Generate on auth server with:
        tctl tokens add --type=node --ttl=1h
      '';
    };
    
    dataDir = mkOption {
      type = types.str;
      default = "/var/lib/teleport";
      description = "Data directory for Teleport";
    };
    
    logLevel = mkOption {
      type = types.enum [ "DEBUG" "INFO" "WARN" "ERROR" ];
      default = "INFO";
      description = "Log level";
    };
    
    environment = mkOption {
      type = types.str;
      default = "development";
      description = "Environment label";
    };
    
    commands = mkOption {
      type = types.attrsOf (types.listOf types.str);
      default = {};
      example = {
        hostname = [ "hostname" ];
        kernel = [ "uname" "-r" ];
      };
      description = "Dynamic labels (commands that run periodically)";
    };
  };
  
  config = mkIf cfg.enable {
    # Ensure Teleport package is available
    environment.systemPackages = [ pkgs.teleport ];
    
    # Create data directory
    systemd.tmpfiles.rules = [
      "d ${cfg.dataDir} 0700 teleport teleport -"
    ];
    
    # Create teleport user
    users.users.teleport = {
      isSystemUser = true;
      group = "teleport";
      home = cfg.dataDir;
      description = "Teleport SSH node service user";
    };
    
    users.groups.teleport = {};
    
    # Systemd service
    systemd.services.teleport-node = {
      description = "Teleport SSH Node";
      after = [ "network.target" "tailscaled.service" ];
      wants = [ "network.target" ];
      wantedBy = [ "multi-user.target" ];
      
      serviceConfig = {
        Type = "simple";
        User = "teleport";
        Group = "teleport";
        ExecStart = "${pkgs.teleport}/bin/teleport start --config=${teleportConfigFile}";
        ExecReload = "${pkgs.coreutils}/bin/kill -HUP $MAINPID";
        Restart = "on-failure";
        RestartSec = "5s";
        LimitNOFILE = 65536;
        
        # Security hardening
        PrivateTmp = true;
        ProtectSystem = "strict";
        ProtectHome = true;
        ReadWritePaths = [ cfg.dataDir ];
        NoNewPrivileges = true;
      };
    };
  };
}
