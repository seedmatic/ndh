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
          name = "vmlan0";  # lima vmnet bridge
        }
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:02";
          name = "vmwan0";  # lima vmnet shared
        }
      ];
      description = ''
        List of network interfaces to rename based on MAC addresses.
        MAC addresses match the actual Lima VM interface MACs.
        Default mapping (for hostname 'bioskop' -> hash '27'):
        - 10:66:6a:4c:27:01 -> vmlan0 (matches lima-shared, bridged LAN)
        - 10:66:6a:4c:27:02 -> vmwan0 (matches lima-bridge, NAT)
        
        Scheme: OUI:LIMA:HOST:IF  
        - OUI: 10:66:6a (local/private)
        - LIMA: 0x4C (76, 'L' for Lima)
        - HOST: Hash-derived unique byte per Darwin host
        - IF: Interface index (01=primary, 02=secondary)
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

    # Helpful environment variables
    environment.variables = {
      LIMA_LAN_IFACE = "vmlan0";          # Bridged interface for home LAN access (udev renamed)
      LIMA_NAT_IFACE = "vmwan0";          # NAT interface for internet egress (udev renamed)
      LIMA_PRIMARY_IFACE = "vmlan0";      # Primary interface (same as LIMA_LAN_IFACE)
      LIMA_SECONDARY_IFACE = "vmwan0";    # Secondary interface (same as LIMA_NAT_IFACE)
    };
  };
}
