{ config, lib, hostProfile ? null, ... }:

let
  inherit (lib) mkOption types mkIf;
  cfg = config.lima.networkInterfaces;
  
  # Resolve host profile - prefer injected specialArg, fall back to config
  resolvedHostProfile = if hostProfile != null then hostProfile else config.profile.host;
  
  # Derive effective hostname (use alias if set, otherwise hostName)
  effectiveHostName = if (resolvedHostProfile ? hostAlias && resolvedHostProfile.hostAlias != null && resolvedHostProfile.hostAlias != "")
    then resolvedHostProfile.hostAlias
    else resolvedHostProfile.hostName;
  
  # Generate unique host byte from hostname hash (matching actual Lima VM MACs)
  # Use single byte that matches the existing Lima VM interface MACs
  hostByteHex = let
    hash = builtins.hashString "sha256" effectiveHostName;
    # Take first 2 hex chars from hash - matches existing Lima VM: 27 for bioskop
  in lib.strings.toLower (builtins.substring 0 2 hash);
  
in {
  options.lima.networkInterfaces = {
    enable = mkOption {
      type = types.bool;
      default = config.limaHost.isGuest;
      description = "Enable Lima network interface naming based on MAC addresses.";
    };

    interfaces = mkOption {
      type = types.listOf (types.submodule {
        options = {
          macAddress = mkOption {
            type = types.str;
            description = "MAC address of the interface";
            example = "10:66:6a:4c:a3:01";
          };
          name = mkOption {
            type = types.str;
            description = "Desired interface name";
            example = "vmlan0 or vmwan0";
          };
        };
      });
      default = [
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:00";
          name = "vznat0";  # lima vzNAT
        }
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:01";
          name = "vmlan0";  # lima vmnet bridged (for Incus lan-br bridge member)
        }
      ];
      description = ''
        List of network interfaces to rename based on MAC addresses.
        MAC addresses match the actual Lima VM interface MACs.
        Default mapping (for hostname 'bioskop' -> hash '27'):
        - 10:66:6a:4c:27:00 -> vznat0 (Lima vzNAT management)
        - 10:66:6a:4c:27:01 -> vmlan0 (Incus lan-br bridge member for container LAN access)
        
        Scheme: OUI:LIMA:HOST:IF  
        - OUI: 10:66:6a (local/private)
        - LIMA: 0x4C (76, 'L' for Lima)
        - HOST: Hash-derived unique byte per Darwin host
        - IF: Interface index (00=vznat0, 01=vmlan0)
      '';
    };
  };

  config = mkIf cfg.enable {
    # Use systemd-networkd for predictable interface naming (rename only)
    systemd.network.enable = lib.mkDefault true;

    # Disable wait-online: we only rename interfaces; they may be configured by other mechanisms (e.g. kernel/Lima DHCP)
    # Prevents 120s timeout because links are 'not managed by networkd'. If later you add .network files, remove this.
    systemd.network.wait-online.enable = false;

    # Create .link files for each interface to rename based on MAC address
    systemd.network.links = builtins.listToAttrs (
      map (iface: {
        name = "10-${iface.name}";
        value = {
          matchConfig = { MACAddress = iface.macAddress; };
          linkConfig = {
            Name = iface.name;
            MACAddressPolicy = "persistent"; # preserve MAC (no randomization)
          };
        };
      }) cfg.interfaces
    );

    # Configure vmlan0 to remain unconfigured (for Incus bridge membership)
    systemd.network.networks."50-vmlan0" = {
      matchConfig.Name = "vmlan0";
      linkConfig = {
        # Keep interface up but unconfigured
        Unmanaged = "no";
        RequiredForOnline = "no";
      };
      networkConfig = {
        # Disable all address configuration
        DHCP = "no";
        IPv6AcceptRA = "no";
        LinkLocalAddressing = "no";
      };
    };

    # Helpful environment variables
    environment.variables = {
      LIMA_BRIDGE_IFACE = "vmlan0";       # Incus lan-br bridge member (unmanaged by NetworkManager)
      # Note: Lima VM SSH management uses enp0s1 (built-in), not vmlan0
    };
  };
}
