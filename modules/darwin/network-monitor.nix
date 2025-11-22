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
  monitorScript = pkgs.writeShellScript "network-monitor-check.sh" ''
    set -euo pipefail
    LOG="/var/log/network-monitor.log"
    {
      echo "[$(date)] Network monitor check start (mode: ${cfg.mode})"

      check_interface() {
        local iface="$1"
        if ifconfig "${iface}" >/dev/null 2>&1; then
          local status=$(ifconfig "${iface}" | grep "status:" | awk '{print $2}')
          local has_ip=0
          if ifconfig "${iface}" | grep -q "inet "; then
            has_ip=1
          fi
          echo "$status:$has_ip"
        else
          echo "not_found:0"
        fi
      }

      manage_bonded_network() {
        echo "[$(date)] Checking bonded network (${cfg.bondInterface})"

        if ! ifconfig "${cfg.bondInterface}" >/dev/null 2>&1; then
          echo "[$(date)] Bond interface ${cfg.bondInterface} not found"
          return
        fi

        if ! ipconfig getifaddr "${cfg.bondInterface}" >/dev/null 2>&1; then
          echo "[$(date)] Bond ${cfg.bondInterface} has no IP, restoring DHCP..."
          ipconfig set "${cfg.bondInterface}" DHCP
        fi

        for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
          if netstat -rn | grep -q "^default.*$bridge"; then
            echo "[$(date)] Removing default route from Lima bridge $bridge"
            route -n delete default -ifscope "$bridge" 2>/dev/null || true
          fi
        done

        if netstat -rn | grep -q "^default.*en1"; then
          echo "[$(date)] Removing Wi-Fi default route (bond takes priority)"
          route -n delete default -ifscope en1 2>/dev/null || true
        fi
      }

      manage_individual_interfaces() {
        echo "[$(date)] Checking individual interface priorities"

        local primary="${cfg.primaryInterface}"
        local backup="${cfg.backupInterface}"
        local primary_status=$(check_interface "$primary")
        echo "[$(date)] Primary interface $primary status: $primary_status"

        case "$primary_status" in
          "active:1")
            local primary_gateway=$(netstat -rn | grep "^default.*$primary" | awk '{print $2}' | head -1)
            if [ -n "$primary_gateway" ]; then
              echo "[$(date)] Reasserting primary route via $primary (metric ${toString cfg.routeMetrics.primary})"
              route -n delete default -ifscope "$primary" 2>/dev/null || true
              route -n add default "$primary_gateway" -ifscope "$primary" -hopcount ${toString cfg.routeMetrics.primary} 2>/dev/null || true
            else
              echo "[$(date)] Primary $primary active but missing default route, renewing DHCP"
              ipconfig set "$primary" DHCP
              sleep 2
            fi

            ${concatMapStringsSep "\n            " (iface: ''
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
            '') cfg.secondaryInterfaces}

            if [ "$backup" != "$primary" ] && if ifconfig "$backup" >/dev/null 2>&1; then
              local backup_gateway=$(netstat -rn | grep "^default.*$backup" | awk '{print $2}' | head -1)
              if [ -n "$backup_gateway" ]; then
                echo "[$(date)] Configuring backup $backup with metric ${toString cfg.routeMetrics.backup}"
                route -n delete default -ifscope "$backup" 2>/dev/null || true
                route -n add default "$backup_gateway" -ifscope "$backup" -hopcount ${toString cfg.routeMetrics.backup} 2>/dev/null || true
              fi
            fi
            ;;

          "active:0"|"inactive:0")
            echo "[$(date)] Primary $primary unavailable, promoting backup $backup"
            if ifconfig "$backup" >/dev/null 2>&1; then
              ifconfig "$backup" up 2>/dev/null || true
              local backup_status=$(check_interface "$backup")
              if [ "$backup_status" != "active:1" ]; then
                ipconfig set "$backup" DHCP
                sleep 2
              fi
              local backup_gateway=$(netstat -rn | grep "^default.*$backup" | awk '{print $2}' | head -1)
              if [ -n "$backup_gateway" ]; then
                echo "[$(date)] Setting $backup as primary route (metric ${toString cfg.routeMetrics.primary})"
                route -n delete default -ifscope "$backup" 2>/dev/null || true
                route -n add default "$backup_gateway" -ifscope "$backup" -hopcount ${toString cfg.routeMetrics.primary} 2>/dev/null || true
              fi
            fi
            ;;
        esac

        for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
          if netstat -rn | grep -q "^default.*$bridge"; then
            echo "[$(date)] Removing default route from Lima bridge $bridge"
            route -n delete default -ifscope "$bridge" 2>/dev/null || true
          fi
        done
      }

      if [ "${cfg.mode}" = "bonded" ]; then
        manage_bonded_network
      else
        manage_individual_interfaces
      fi

      echo "[$(date)] Network monitor check complete"
    } >>"$LOG" 2>&1
  '';
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