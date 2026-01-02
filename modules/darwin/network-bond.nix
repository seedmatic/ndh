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

  bondInterfaces = concatStringsSep " " cfg.interfaces;

  activationInterfaceChecks = concatMapStringsSep "\n" (iface: ''
    if ! ifconfig ${iface} >/dev/null 2>&1; then
      echo "[bond] ERROR: Interface ${iface} not found, skipping bond setup" >> "$LOG"
      exit 0
    fi
  '') cfg.interfaces;

  daemonInterfaceChecks = concatMapStringsSep "\n" (iface: ''
    if ! ifconfig ${iface} >/dev/null 2>&1; then
      echo "[bond] ERROR: Interface ${iface} not found, skipping bond setup" >&2
      exit 0
    fi
  '') cfg.interfaces;

  bondDetach = concatMapStringsSep "\n" (
    iface: "ifconfig bond0 -bonddev ${iface} || true"
  ) cfg.interfaces;

  releaseInterfaces = concatMapStringsSep "\n" (
    iface: "ipconfig set ${iface} NONE || true"
  ) cfg.interfaces;

  bondAttach = concatMapStringsSep "\n" (iface: "ifconfig bond0 bonddev ${iface}") cfg.interfaces;

  dhcpActivationBlock = optionalString cfg.dhcp ''
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
  '';

  dhcpDaemonBlock = optionalString cfg.dhcp ''
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
  '';

  clearMemberIps = concatMapStringsSep "\n" (iface: ''
    if ifconfig ${iface} | grep -q "inet 169.254\|inet [0-9]"; then
      echo "[$(date)] Clearing IP from ${iface}" >> "$LOG"
      ipconfig set ${iface} NONE 2>/dev/null || true
    fi'') cfg.interfaces;

  networkBondActivationScript = pkgs.runCommand "network-bond-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./network-bond.d/post-activation.sh {
        activationInterfaceChecks = activationInterfaceChecks;
        bondInterfaces = bondInterfaces;
        bondDetach = bondDetach;
        releaseInterfaces = releaseInterfaces;
        bondAttach = bondAttach;
        bondMode = cfg.mode;
        dhcpActivationBlock = dhcpActivationBlock;
      }
    } "$out"
    chmod +x "$out"
  '';

  networkBondDaemonScript = pkgs.replaceVars ./network-bond.d/daemon.sh {
    daemonInterfaceChecks = daemonInterfaceChecks;
    bondInterfaces = bondInterfaces;
    bondDetach = bondDetach;
    releaseInterfaces = releaseInterfaces;
    bondAttach = bondAttach;
    bondMode = cfg.mode;
    dhcpDaemonBlock = dhcpDaemonBlock;
  };

  wakeMonitor = pkgs.writeShellScript "bond-wake-monitor" (
    builtins.readFile ./network-bond.d/bond-wake-monitor.sh
  );

  networkBondMaintainScript = pkgs.replaceVars ./network-bond.d/maintain.sh {
    clearMemberIps = clearMemberIps;
  };
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
      script = networkBondDaemonScript;

      serviceConfig = {
        RunAtLoad = true;
        KeepAlive = false;
        StandardErrorPath = "/var/log/network-bond.log";
        StandardOutPath = "/var/log/network-bond.log";
      };
    };

    # Launchd daemon to reconfigure bond on wake from sleep
    # Uses a wrapper script that monitors system power events
    launchd.daemons.network-bond-wake = {
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
      script = networkBondMaintainScript;

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
