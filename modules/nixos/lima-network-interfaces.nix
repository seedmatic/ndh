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
  
  # Generate unique host byte from hostname hash (matching darwin lima-config.nix)
  hostByteHex = let
    hash = builtins.hashString "sha256" effectiveHostName;
    rawByte = lib.strings.toInt 16 (builtins.substring 0 2 hash);
    boundedByte = (rawByte % 239) + 16; # Range: 16-254 (0x10-0xfe)
  in lib.strings.toLower (builtins.substring 0 2 (lib.strings.fixedWidthString 2 "0" (lib.trivial.toHexString boundedByte)));
  
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
            example = "lima-shared";
          };
        };
      });
      default = [
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:01";
          name = "lima-shared";
        }
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:02";
          name = "lima-bridge";
        }
      ];
      description = ''
        List of network interfaces to rename based on MAC addresses.
        MAC addresses are host-unique via hash of hostname in byte 5.
        Default mapping:
        - 10:66:6a:4c:<host>:01 -> lima-shared (socket_vmnet NAT)
        - 10:66:6a:4c:<host>:02 -> lima-bridge (bridged to host LAN)
        
        Scheme: OUI:LIMA:HOST:IF
        - OUI: 10:66:6a (local/private)
        - LIMA: 0x4C (76, 'L' for Lima)
        - HOST: Hash-derived unique byte per Darwin host
        - IF: Interface index
      '';
    };
  };

  config = mkIf cfg.enable {
    # Use systemd-networkd for predictable interface naming
    systemd.network.enable = lib.mkDefault true;
    
    # Create .link files for each interface to rename based on MAC address
    systemd.network.links = builtins.listToAttrs (
      map (iface: {
        name = "10-${iface.name}";
        value = {
          matchConfig = {
            MACAddress = iface.macAddress;
          };
          linkConfig = {
            Name = iface.name;
            # Preserve MAC address (don't randomize)
            MACAddressPolicy = "persistent";
          };
        };
      }) cfg.interfaces
    );

    # Add helpful environment variables
    environment.variables = {
      LIMA_SHARED_IFACE = "lima-shared";
      LIMA_BRIDGE_IFACE = "lima-bridge";
    };
  };
}
