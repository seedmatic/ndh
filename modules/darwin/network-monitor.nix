# Generic network interface monitoring and management service
# Handles both bonded and non-bonded multi-interface scenarios
{
  config,
  lib,
  pkgs,
  ...
}:
with lib; let
  cfg = config.networking.monitor;
  secondaryRouteStatements =
    concatMapStringsSep "\n\n" (iface: ''
        if ifconfig ${iface} >/dev/null 2>&1; then
          local status=$(ifconfig ${iface} | grep "status:" | awk '{print $2}')
          if [ "$status" = "active" ] && ifconfig ${iface} | grep -q "inet "; then
            local gateway=$(netstat -rn | grep "^default.*${iface}" | awk '{print $2}' | head -1)
            if [ -n "$gateway" ]; then
              echo "[$(date)] Configuring ${iface} as secondary with metric ${toString cfg.routeMetrics.secondary}"
              route -n delete default -ifscope ${iface} 2>/dev/null || true
              route -n add default "$gateway" -ifscope ${iface} -hopcount ${toString cfg.routeMetrics.secondary} 2>/dev/null || true
            fi
          fi
        fi
    '') cfg.secondaryInterfaces;

  monitorScript = pkgs.substituteAll {
    name = "network-monitor.sh";
    src = ./network-monitor.sh;
    isExecutable = true;
    inherit (cfg) mode bondInterface primaryInterface backupInterface;
    routeMetricPrimary = toString cfg.routeMetrics.primary;
    routeMetricBackup = toString cfg.routeMetrics.backup;
    inherit secondaryRouteStatements;
  };
in {
  options.networking.monitor = {
    enable = mkEnableOption "network interface monitoring and management";

    interfaces = mkOption {
      type = types.listOf types.str;
      default = ["en0" "en1" "en8"];
      example = ["en0" "en1" "en8"];
      description = ''
        List of network interfaces to monitor and manage priority for.
        First interface has highest priority, last has lowest.
      '';
    };

    primaryInterface = mkOption {
      type = types.str;
      default = "en0";
      example = "en0";
      description = ''
        Primary network interface that should have the default route.
        Usually the built-in Ethernet interface.
      '';
    };

    backupInterface = mkOption {
      type = types.str;
      default = "en1";
      example = "en1";
      description = ''
        Backup interface (usually Wi-Fi) that should be available
        but with lower priority than primary.
      '';
    };

    secondaryInterfaces = mkOption {
      type = types.listOf types.str;
      default = ["en8"];
      example = ["en8"];
      description = ''
        Interfaces that should be configured with lower priority routes.
        These interfaces remain active but with higher metric (lower priority) routes.
      '';
    };

    routeMetrics = mkOption {
      type = types.attrsOf types.int;
      default = {
        primary = 100;      # Lowest metric = highest priority
        backup = 200;       # Medium priority for Wi-Fi backup
        secondary = 300;    # Higher metric = lower priority for secondary interfaces
      };
      description = ''
        Route metrics (priorities) for different interface types.
        Lower numbers = higher priority.
      '';
    };

    bondInterface = mkOption {
      type = types.str;
      default = "bond0";
      example = "bond0";
      description = ''
        Bond interface name to check for. If this interface exists and is active,
        the service will run in bonded mode. Otherwise, it runs in individual mode.
      '';
    };

    mode = mkOption {
      type = types.enum ["bonded" "individual"];
      default = if config.networking.bond.enable then "bonded" else "individual";
      description = ''
        Network monitoring mode:
        - bonded: Monitor and maintain bond interface
        - individual: Manage individual interface priorities
      '';
    };

    checkInterval = mkOption {
      type = types.int;
      default = 30;
      description = ''
        Interval in seconds between network state checks.
        (Deprecated: retained for compatibility; event daemon now runs on demand.)
      '';
    };
  };

  config = mkIf cfg.enable {
    launchd.daemons.network-monitor-events = {
      script = ''
        #!/bin/bash
        LOG="/var/log/network-monitor-events.log"
        echo "[$(date)] Network state changed, running monitor check (mode: ${cfg.mode})" >> "$LOG"
        ${monitorScript}
        echo "[$(date)] Network event handling complete" >> "$LOG"
      '';

      serviceConfig = {
        RunAtLoad = true;
        WatchPaths = [
          "/Library/Preferences/SystemConfiguration/preferences.plist"
          "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
        ];
        StandardErrorPath = "/var/log/network-monitor-events.log";
        StandardOutPath = "/var/log/network-monitor-events.log";
      };
    };

    system.activationScripts.postActivation.text = mkAfter ''
      echo "[network-monitor] Configuring network monitoring (mode: ${cfg.mode})" >&2

      ${if cfg.mode == "bonded" then ''
        if ifconfig "${cfg.bondInterface}" >/dev/null 2>&1; then
          echo "[network-monitor] Bond interface ${cfg.bondInterface} detected" >&2
        else
          echo "[network-monitor] Warning: Bond interface ${cfg.bondInterface} not found" >&2
        fi
      '' else ''
        echo "[network-monitor] Configuring individual interface route priorities" >&2

        ${concatMapStringsSep "\n        " (iface: ''
          if ifconfig ${iface} >/dev/null 2>&1; then
            echo "[network-monitor] Configuring secondary interface ${iface} with metric ${toString cfg.routeMetrics.secondary}" >&2
            ifconfig ${iface} up 2>/dev/null || true
            if ! ifconfig ${iface} | grep -q "inet "; then
              ipconfig set ${iface} DHCP 2>/dev/null || true
            fi
          fi
        '') cfg.secondaryInterfaces}

        if ifconfig "${cfg.primaryInterface}" >/dev/null 2>&1; then
          echo "[network-monitor] Ensuring primary interface ${cfg.primaryInterface} has highest priority" >&2
          ifconfig "${cfg.primaryInterface}" up 2>/dev/null || true
        fi

        if ifconfig "${cfg.backupInterface}" >/dev/null 2>&1; then
          echo "[network-monitor] Configuring backup interface ${cfg.backupInterface} with metric ${toString cfg.routeMetrics.backup}" >&2
          ifconfig "${cfg.backupInterface}" up 2>/dev/null || true
        fi
      ''}

      echo "[network-monitor] Network monitoring configured successfully" >&2
      ${monitorScript}
    '';
  };
}