# Network bonding configuration for macOS
# Declaratively configures link aggregation (bonding) between multiple Ethernet interfaces
{
  config,
  lib,
  pkgs,
  ...
}:
with lib;
let
  cfg = config.networking.bond;

  networkBondActivationScript = pkgs.writeShellScript "network-bond-activation.sh" ''
    set -euo pipefail
    LOG="/var/log/network-bond-activation.log"
    {
      echo "[bond] Configuring network bond interface"

      ${concatMapStringsSep "\n" (iface: ''
        if ! ifconfig ${iface} >/dev/null 2>&1; then
          echo "[bond] ERROR: Interface ${iface} not found, skipping bond setup"
          exit 0
        fi
      '') cfg.interfaces}

      BOND_EXISTS=0
      if ifconfig bond0 >/dev/null 2>&1; then
        BOND_EXISTS=1
      fi

      if [ "$BOND_EXISTS" -eq 1 ]; then
        CURRENT_MEMBERS=$(ifconfig bond0 | awk '/bond interfaces:/ {for(i=3;i<=NF;i++) print $i}' | sort | tr '\n' ' ' | xargs)
        DESIRED_MEMBERS=$(printf '%s\n' ${concatStringsSep " " cfg.interfaces} | sort | tr '\n' ' ' | xargs)

        BOND_HAS_IP=0
        if ipconfig getifaddr bond0 >/dev/null 2>&1; then
          BOND_HAS_IP=1
        fi

        if [ "$CURRENT_MEMBERS" = "$DESIRED_MEMBERS" ] && [ "$BOND_HAS_IP" -eq 1 ]; then
          echo "[bond] Bond configuration unchanged and has IP, skipping"
          exit 0
        else
          if [ "$CURRENT_MEMBERS" != "$DESIRED_MEMBERS" ]; then
            echo "[bond] Bond configuration changed, reconfiguring..."
          else
            echo "[bond] Bond exists but has no IP, reconfiguring..."
          fi
          ${concatMapStringsSep "\n" (iface: "ifconfig bond0 -bonddev ${iface} || true") cfg.interfaces}
          ifconfig bond0 destroy || true
        fi
      fi

      echo "[bond] Creating bond interface with mode ${cfg.mode}"

      ${concatMapStringsSep "\n" (iface: "ipconfig set ${iface} NONE || true") cfg.interfaces}

      ifconfig bond0 create || true

      ${concatMapStringsSep "\n" (iface: "ifconfig bond0 bonddev ${iface}") cfg.interfaces}

      ${concatMapStringsSep "\n" (iface: "ipconfig set ${iface} NONE || true") cfg.interfaces}

      ifconfig bond0 bondmode ${cfg.mode}
      ifconfig bond0 up

      ${optionalString cfg.dhcp ''
        echo "[bond] Configuring DHCP on bond0"
        ipconfig set bond0 DHCP
        ipconfig set bond0 AUTOMATIC-V6
        sleep 3

        echo "[bond] Setting network service priority (bond0 > WiFi)"
        networksetup -listallnetworkservices | grep -v "^An asterisk" | while read -r service; do
          case "$service" in
            *"USB"*|*"Ethernet"*)
              ;;
            *"Wi-Fi"*)
              route -n delete default -ifscope en1 2>/dev/null || true
              ;;
          esac
        done

        for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
          route -n delete default -ifscope "$bridge" 2>/dev/null || true
        done
      ''}

      echo "[bond] Bond interface configured successfully"
    } >>"$LOG" 2>&1
  '';
in
{
  options.networking.bond = {
    enable = mkEnableOption "network interface bonding";

    interfaces = mkOption {
      type = types.listOf types.str;
      default = [ ];
      example = [
        "en0"
        "en8"
      ];
      description = ''
        List of network interfaces to bond together.
        Typically the built-in Ethernet (en0) and USB Ethernet adapter (en8).
      '';
    };

    mode = mkOption {
      type = types.enum [
        "static"
        "lacp"
      ];
      default = "static";
      example = "static";
      description = ''
        Bond mode to use:
        - static: Static link aggregation (no LACP protocol, distributes traffic)
        - lacp: LACP/802.3ad (requires switch support for dynamic aggregation)

        Note: macOS only supports these two modes, unlike Linux bond modes 0-6.
      '';
    };

    dhcp = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Use DHCP for the bonded interface. If false, manual IP configuration required.
      '';
    };
  };

  config = mkIf cfg.enable {
    # Launchd daemon to configure bond at boot and on wake
    launchd.daemons.network-bond = {
      script = ''
        echo "[bond] Configuring network bond interface (triggered by: ''${1:-boot})" >&2

        # Wait for network interfaces to be available
        sleep 5

        # Check if all interfaces exist
        ${concatMapStringsSep "\n" (iface: ''
          if ! ifconfig ${iface} >/dev/null 2>&1; then
            echo "[bond] ERROR: Interface ${iface} not found, skipping bond setup" >&2
            exit 0
          fi
        '') cfg.interfaces}

        # Check if bond already exists with correct configuration
        if ifconfig bond0 >/dev/null 2>&1; then
          CURRENT_MEMBERS=$(ifconfig bond0 | awk '/bond interfaces:/ {for(i=3;i<=NF;i++) print $i}' | sort | tr '\n' ' ' | xargs)
          DESIRED_MEMBERS=$(printf '%s\n' ${concatStringsSep " " cfg.interfaces} | sort | tr '\n' ' ' | xargs)
          
          if [ "$CURRENT_MEMBERS" = "$DESIRED_MEMBERS" ]; then
            echo "[bond] Bond already configured correctly" >&2
            exit 0
          fi
          
          # Destroy existing bond if configuration differs
          echo "[bond] Reconfiguring bond..." >&2
          ${concatMapStringsSep "\n" (iface: "ifconfig bond0 -bonddev ${iface} || true") cfg.interfaces}
          ifconfig bond0 destroy || true
        fi

        echo "[bond] Creating bond interface with mode ${cfg.mode}" >&2

        # Release DHCP leases on individual interfaces and disable auto-config
        ${concatMapStringsSep "\n" (iface: "ipconfig set ${iface} NONE || true") cfg.interfaces}

        # Create bond interface
        ifconfig bond0 create || true

        # Add interfaces to bond first (this should prevent them from getting IPs)
        ${concatMapStringsSep "\n" (iface: "ifconfig bond0 bonddev ${iface}") cfg.interfaces}

        # Ensure member interfaces don't get IP addresses after bonding
        ${concatMapStringsSep "\n" (iface: "ipconfig set ${iface} NONE || true") cfg.interfaces}

        # Set bond mode
        ifconfig bond0 bondmode ${cfg.mode}

        # Bring bond interface up
        ifconfig bond0 up

        # Configure DHCP on bond interface
        ${optionalString cfg.dhcp ''
          echo "[bond] Configuring DHCP on bond0" >&2
          ipconfig set bond0 DHCP
          ipconfig set bond0 AUTOMATIC-V6

          # Ensure bond0 has priority over WiFi by managing service order
          echo "[bond] Setting network service priority (bond0 > WiFi)" >&2
          networksetup -listallnetworkservices | grep -v "^An asterisk" | while read -r service; do
            case "$service" in
              *"USB"*|*"Ethernet"*) 
                # These are likely the bond members, skip
                ;;
              *"Wi-Fi"*)
                # Lower WiFi priority by removing and re-adding default route
                route -n delete default -ifscope en1 2>/dev/null || true
                ;;
            esac
          done
        ''}

        echo "[bond] Bond interface configured successfully" >&2
      '';

      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
        StandardErrorPath = "/var/log/network-bond.log";
        StandardOutPath = "/var/log/network-bond.log";
      };
    };

    # Launchd daemon to reconfigure bond on wake from sleep
    # Uses a wrapper script that monitors system power events
    launchd.daemons.network-bond-wake =
      let
        wakeMonitor = pkgs.writeShellScript "bond-wake-monitor" ''
          #!/bin/bash
          LOG="/var/log/network-bond-wake.log"

          echo "[$(date)] Bond wake monitor started" >> "$LOG"

          # Monitor kernel power management events for wake from sleep
          # Filter for actual wake events using predicate to avoid false positives
          log stream --level info --predicate 'subsystem == "com.apple.iokit.power" AND eventMessage CONTAINS "Wake from"' --style compact 2>/dev/null | \
          while read -r line; do
            echo "[$(date)] System woke from sleep" >> "$LOG"
            
            # Wait for network interfaces to come up
            sleep 10
            
            # Check if bond0 exists and renew DHCP
            if ifconfig bond0 >/dev/null 2>&1; then
              echo "[$(date)] Renewing DHCP on bond0..." >> "$LOG"
              ipconfig set bond0 DHCP
              ipconfig set bond0 AUTOMATIC-V6
              sleep 3
              
              # Fix routing - remove WiFi and Lima bridge default routes
              route -n delete default -ifscope en1 2>/dev/null || true
              for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
                route -n delete default -ifscope "$bridge" 2>/dev/null || true
              done
              
              # Log the result
              if ipconfig getifaddr bond0 >/dev/null 2>&1; then
                IP=$(ipconfig getifaddr bond0)
                echo "[$(date)] Bond0 IP: $IP" >> "$LOG"
              else
                echo "[$(date)] WARNING: bond0 did not get an IP address" >> "$LOG"
              fi
            else
              echo "[$(date)] WARNING: bond0 interface not found" >> "$LOG"
            fi
          done
        '';
      in
      {
        script = "${wakeMonitor}";

        serviceConfig = {
          RunAtLoad = true;
          KeepAlive = true; # Keep running to monitor wake events
          StandardErrorPath = "/var/log/network-bond-wake.log";
          StandardOutPath = "/var/log/network-bond-wake.log";
        };
      };

    # Event-driven daemon to maintain bond priority when network state changes
    launchd.daemons.network-bond-maintain = {
      script = ''
        #!/bin/bash
        set -x  # Enable trace mode for debugging
        LOG="/var/log/network-bond-maintain.log"
        echo "[$(date)] Network state changed, checking bond configuration..." >> "$LOG"

        # Check if bond0 exists
        if ! ifconfig bond0 >/dev/null 2>&1; then
          echo "[$(date)] bond0 does not exist, exiting" >> "$LOG"
          exit 0
        fi

        # Check if bond0 has an IP, if not restore it
        if ! ipconfig getifaddr bond0 >/dev/null 2>&1; then
          echo "[$(date)] bond0 has no IP, restoring DHCP..." >> "$LOG"
          ipconfig set bond0 DHCP
          ipconfig set bond0 AUTOMATIC-V6
          sleep 3
        fi

        # Clear any IPs on member interfaces
        ${concatMapStringsSep "\n        " (iface: ''
          if ifconfig ${iface} | grep -q "inet 169.254\\|inet [0-9]"; then
            echo "[$(date)] Clearing IP from ${iface}" >> "$LOG"
            ipconfig set ${iface} NONE 2>/dev/null || true
          fi'') cfg.interfaces}

        # Ensure WiFi doesn't have the primary default route
        # Set network service order: bond members (Ethernet, USB LAN) before WiFi
        echo "[$(date)] Setting network service order: bond members > WiFi" >> "$LOG"

        # Get ALL network services (including disabled ones, but strip asterisks)
        SERVICES=$(networksetup -listallnetworkservices | tail -n +2 | sed 's/^\*//')

        # Build ordered list: bond members first, then others, WiFi last
        declare -a ORDERED_ARRAY
        WIFI_SERVICE=""

        # First pass: collect bond members
        while IFS= read -r service; do
          [ -z "$service" ] && continue
          case "$service" in
            *"Ethernet"*|*"USB"*"LAN"*)
              ORDERED_ARRAY+=("$service")
              ;;
          esac
        done <<< "$SERVICES"

        # Second pass: collect non-WiFi, non-bond services
        while IFS= read -r service; do
          [ -z "$service" ] && continue
          case "$service" in
            *"Ethernet"*|*"USB"*"LAN"*|*"Wi-Fi"*)
              # Skip - already handled or will be last
              if [[ "$service" == *"Wi-Fi"* ]]; then
                WIFI_SERVICE="$service"
              fi
              ;;
            *)
              ORDERED_ARRAY+=("$service")
              ;;
          esac
        done <<< "$SERVICES"

        # Add WiFi last
        if [ -n "$WIFI_SERVICE" ]; then
          ORDERED_ARRAY+=("$WIFI_SERVICE")
        fi

        # Apply new order if WiFi was found and reordering needed
        if [ -n "$WIFI_SERVICE" ] && [ ''${#ORDERED_ARRAY[@]} -gt 0 ]; then
          echo "[$(date)] New service order: ''${ORDERED_ARRAY[*]}" >> "$LOG"
          networksetup -ordernetworkservices "''${ORDERED_ARRAY[@]}" 2>&1 >> "$LOG" || true
          
          # Ensure bond0 route has higher priority than WiFi when bond0 is available
          if ipconfig getifaddr bond0 >/dev/null 2>&1; then
            BOND_GATEWAY=$(route -n get default -ifscope bond0 2>/dev/null | awk '/gateway:/ {print $2}' || echo "192.168.1.254")
            if [ -n "$BOND_GATEWAY" ] && [ "$BOND_GATEWAY" != "" ]; then
              echo "[$(date)] Adding priority default route via bond0 ($BOND_GATEWAY)" >> "$LOG"
              # Add a more specific route that takes precedence over WiFi default route
              route -n add default "$BOND_GATEWAY" -ifscope bond0 2>&1 >> "$LOG" || true
            fi
          fi
        fi

        # Remove default routes from Lima bridge interfaces (bridge100, bridge101, etc.)
        for bridge in $(ifconfig -l | tr ' ' '\n' | grep '^bridge'); do
          if netstat -rn | grep -q "^default.*$bridge"; then
            echo "[$(date)] Lima bridge $bridge has default route, removing..." >> "$LOG"
            route -n delete default -ifscope "$bridge" 2>/dev/null || true
          fi
        done

        echo "[$(date)] Bond maintenance complete" >> "$LOG"
      '';

      serviceConfig = {
        RunAtLoad = true;
        WatchPaths = [
          "/Library/Preferences/SystemConfiguration/preferences.plist"
          "/Library/Preferences/SystemConfiguration/NetworkInterfaces.plist"
        ];
        StandardErrorPath = "/var/log/network-bond-maintain.log";
        StandardOutPath = "/var/log/network-bond-maintain.log";
      };
    };

    # Declarative bond configuration via activation script
    system.activationScripts.postActivation.text = mkAfter ''
      ${networkBondActivationScript}
    '';
  };
}
