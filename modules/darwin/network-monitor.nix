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
      '';
    };
  };

  config = mkIf cfg.enable {
    # Network monitoring daemon
    launchd.daemons.network-monitor = {
      script = ''
        #!/bin/bash
        set -x
        LOG="/var/log/network-monitor.log"
        
        log() {
          echo "[$(date)] $1" >> "$LOG"
        }
        
        check_interface() {
          local iface="$1"
          if ifconfig "$iface" >/dev/null 2>&1; then
            local status=$(ifconfig "$iface" | grep "status:" | awk '{print $2}')
            local has_ip=0
            if ifconfig "$iface" | grep -q "inet "; then
              has_ip=1
            fi
            echo "$status:$has_ip"
          else
            echo "not_found:0"
          fi
        }
        
        manage_bonded_network() {
          log "Checking bonded network (${cfg.bondInterface})"
          
          if ! ifconfig "${cfg.bondInterface}" >/dev/null 2>&1; then
            log "Bond interface ${cfg.bondInterface} not found"
            return
          fi
          
          # Check if bond has IP
          if ! ipconfig getifaddr "${cfg.bondInterface}" >/dev/null 2>&1; then
            log "Bond ${cfg.bondInterface} has no IP, restoring DHCP..."
            ipconfig set "${cfg.bondInterface}" DHCP
          fi
          
          # Remove Lima bridge default routes that might conflict
          for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
            if netstat -rn | grep -q "^default.*$bridge"; then
              log "Removing default route from Lima bridge $bridge"
              route -n delete default -ifscope "$bridge" 2>/dev/null || true
            fi
          done
          
          # Ensure bond has priority over WiFi
          if netstat -rn | grep -q "^default.*en1"; then
            log "Removing Wi-Fi default route (bond takes priority)"
            route -n delete default -ifscope en1 2>/dev/null || true
          fi
        }
        
        manage_individual_interfaces() {
          log "Checking individual interface priorities"
          
          local primary="${cfg.primaryInterface}"
          local backup="${cfg.backupInterface}"
          
          # Check primary interface status
          local primary_status=$(check_interface "$primary")
          log "Primary interface $primary status: $primary_status"
          
          case "$primary_status" in
            "active:1")
              # Primary is up and has IP - always ensure it holds the preferred route
              local primary_gateway=$(netstat -rn | grep "^default.*$primary" | awk '{print $2}' | head -1)
              if [ -n "$primary_gateway" ]; then
                log "Reasserting primary route via $primary (metric ${toString cfg.routeMetrics.primary})"
                route -n delete default -ifscope "$primary" 2>/dev/null || true
                route -n add default "$primary_gateway" -ifscope "$primary" -hopcount ${toString cfg.routeMetrics.primary} 2>/dev/null || true
              else
                log "Primary $primary active but missing default route, renewing DHCP"
                ipconfig set "$primary" DHCP
                sleep 2
              fi
              
              # Configure secondary interfaces with lower priority routes
              ${concatMapStringsSep "\n          " (iface: ''
                if ifconfig ${iface} >/dev/null 2>&1; then
                  local ${iface}_status=$(ifconfig ${iface} | grep "status:" | awk '{print $2}')
                  if [ "$${iface}_status" = "active" ]; then
                    # Get current gateway if interface has IP
                    if ifconfig ${iface} | grep -q "inet "; then
                      local gateway=$(netstat -rn | grep "^default.*${iface}" | awk '{print $2}' | head -1)
                      if [ -n "$gateway" ]; then
                        log "Configuring ${iface} as secondary with metric ${toString cfg.routeMetrics.secondary}"
                        # Remove existing default route
                        route -n delete default -ifscope ${iface} 2>/dev/null || true
                        # Add route with higher metric (lower priority)
                        route -n add default "$gateway" -ifscope ${iface} -hopcount ${toString cfg.routeMetrics.secondary} 2>/dev/null || true
                      fi
                    fi
                  fi
                fi
              '') cfg.secondaryInterfaces}
              
              # Manage backup interface with appropriate priority
              if [ "$backup" != "$primary" ]; then
                local backup_status=$(check_interface "$backup")
                case "$backup_status" in
                  "active:1")
                    # Configure backup with medium priority route
                    local backup_gateway=$(netstat -rn | grep "^default.*$backup" | awk '{print $2}' | head -1)
                    if [ -n "$backup_gateway" ]; then
                      log "Configuring backup $backup with metric ${toString cfg.routeMetrics.backup}"
                      # Remove existing default route
                      route -n delete default -ifscope "$backup" 2>/dev/null || true
                      # Add route with medium priority
                      route -n add default "$backup_gateway" -ifscope "$backup" -hopcount ${toString cfg.routeMetrics.backup} 2>/dev/null || true
                    fi
                    ;;
                esac
              fi
              ;;
              
            "active:0"|"inactive:0")
              # Primary is down or has no IP - promote backup to primary priority
              log "Primary $primary unavailable, promoting backup $backup to primary priority"
              
              if ifconfig "$backup" >/dev/null 2>&1; then
                ifconfig "$backup" up 2>/dev/null || true
                local backup_status=$(check_interface "$backup")
                if [ "$backup_status" != "active:1" ]; then
                  ipconfig set "$backup" DHCP
                  sleep 2
                fi
                
                # Set backup interface to primary priority
                local backup_gateway=$(netstat -rn | grep "^default.*$backup" | awk '{print $2}' | head -1)
                if [ -n "$backup_gateway" ]; then
                  log "Setting $backup as primary route (metric ${toString cfg.routeMetrics.primary})"
                  route -n delete default -ifscope "$backup" 2>/dev/null || true
                  route -n add default "$backup_gateway" -ifscope "$backup" -hopcount ${toString cfg.routeMetrics.primary} 2>/dev/null || true
                fi
              fi
              ;;
          esac
          
          # Always remove Lima bridge default routes
          for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
            if netstat -rn | grep -q "^default.*$bridge"; then
              log "Removing default route from Lima bridge $bridge"
              route -n delete default -ifscope "$bridge" 2>/dev/null || true
            fi
          done
        }
        
        # Main monitoring loop
        while true; do
          log "Network monitor check starting (mode: ${cfg.mode})"
          
          ${if cfg.mode == "bonded" then ''
            # Bonded mode - monitor and maintain bond interface
            manage_bonded_network
          '' else ''
            # Individual interface mode - manage interface priorities
            manage_individual_interfaces
          ''}
          
          log "Network monitor check complete, sleeping ${toString cfg.checkInterval}s"
          sleep ${toString cfg.checkInterval}
        done
      '';
      
      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = true;
        StandardErrorPath = "/var/log/network-monitor.log";
        StandardOutPath = "/var/log/network-monitor.log";
      };
    };

    # Event-driven daemon for network state changes
    launchd.daemons.network-monitor-events = {
      script = ''
        #!/bin/bash
        LOG="/var/log/network-monitor-events.log"
        echo "[$(date)] Network state changed, triggering check (mode: ${cfg.mode})..." >> "$LOG"
        
        # Signal the main monitor to run an immediate check
        pkill -USR1 -f "network-monitor" 2>/dev/null || true
        
        ${if cfg.mode == "bonded" then ''
          # Bonded mode - quick bond check
          if ifconfig "${cfg.bondInterface}" >/dev/null 2>&1; then
            if ! ipconfig getifaddr "${cfg.bondInterface}" >/dev/null 2>&1; then
              echo "[$(date)] Bond ${cfg.bondInterface} lost IP, restoring..." >> "$LOG"
              ipconfig set "${cfg.bondInterface}" DHCP
            fi
          fi
        '' else ''
          # Individual mode - quick route priority adjustment
          if ifconfig "${cfg.primaryInterface}" >/dev/null 2>&1; then
            status=$(ifconfig "${cfg.primaryInterface}" | grep "status:" | awk '{print $2}')
            if [ "$status" = "active" ]; then
              # Ensure primary has lowest metric route
              gateway=$(netstat -rn | grep "^default.*${cfg.primaryInterface}" | awk '{print $2}' | head -1)
              if [ -n "$gateway" ]; then
                route -n delete default -ifscope ${cfg.primaryInterface} 2>/dev/null || true
                route -n add default "$gateway" -ifscope ${cfg.primaryInterface} -hopcount ${toString cfg.routeMetrics.primary} 2>/dev/null || true
              fi
              
              # Ensure backup interface has medium priority if active
              if ifconfig "${cfg.backupInterface}" >/dev/null 2>&1; then
                backup_gateway=$(netstat -rn | grep "^default.*${cfg.backupInterface}" | awk '{print $2}' | head -1)
                if [ -n "$backup_gateway" ]; then
                  route -n delete default -ifscope ${cfg.backupInterface} 2>/dev/null || true
                  route -n add default "$backup_gateway" -ifscope ${cfg.backupInterface} -hopcount ${toString cfg.routeMetrics.backup} 2>/dev/null || true
                fi
              fi
            fi
          fi
        ''}
        
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

    # Activation script for initial network configuration
    system.activationScripts.postActivation.text = mkAfter ''
      echo "[network-monitor] Configuring network monitoring (mode: ${cfg.mode})" >&2
      
      ${if cfg.mode == "bonded" then ''
        # Bonded mode - ensure bond is configured
        if ifconfig "${cfg.bondInterface}" >/dev/null 2>&1; then
          echo "[network-monitor] Bond interface ${cfg.bondInterface} detected" >&2
        else
          echo "[network-monitor] Warning: Bond interface ${cfg.bondInterface} not found" >&2
        fi
      '' else ''
        # Individual interface mode - set initial route priorities
        echo "[network-monitor] Configuring individual interface route priorities" >&2
        
        # Configure secondary interfaces with lower priority routes
        ${concatMapStringsSep "\n        " (iface: ''
          if ifconfig ${iface} >/dev/null 2>&1; then
            echo "[network-monitor] Configuring secondary interface ${iface} with metric ${toString cfg.routeMetrics.secondary}" >&2
            # Ensure interface is up and has IP
            ifconfig ${iface} up 2>/dev/null || true
            if ! ifconfig ${iface} | grep -q "inet "; then
              ipconfig set ${iface} DHCP 2>/dev/null || true
            fi
          fi
        '') cfg.secondaryInterfaces}
        
        # Ensure primary interface has highest priority
        if ifconfig "${cfg.primaryInterface}" >/dev/null 2>&1; then
          echo "[network-monitor] Ensuring primary interface ${cfg.primaryInterface} has highest priority" >&2
          ifconfig "${cfg.primaryInterface}" up 2>/dev/null || true
        fi
        
        # Configure backup interface 
        if ifconfig "${cfg.backupInterface}" >/dev/null 2>&1; then
          echo "[network-monitor] Configuring backup interface ${cfg.backupInterface} with metric ${toString cfg.routeMetrics.backup}" >&2
          ifconfig "${cfg.backupInterface}" up 2>/dev/null || true
        fi
      ''}
      
      echo "[network-monitor] Network monitoring configured successfully" >&2
    '';
  };
}