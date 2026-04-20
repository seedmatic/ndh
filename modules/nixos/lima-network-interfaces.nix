{
  config,
  lib,
  hostProfile ? null,
  ...
}:

let
  inherit (lib) mkOption types mkIf;
  cfg = config.lima.networkInterfaces;
  vmProvider =
    if config ? ndh && config.ndh ? vm && config.ndh.vm ? provider then
      config.ndh.vm.provider
    else
      "lima";
  isTartProvider = vmProvider == "tart";
  includeHostAndNatInterfaces = vmProvider == "lima";
  vlanCfg = config.networking.vlan or { };
  vlanEnabled = vlanCfg.enable or false;
  vlanName =
    if vlanEnabled then
      (if (vlanCfg ? name && vlanCfg.name != null) then vlanCfg.name else "vlan${toString vlanCfg.id}")
    else
      null;

  # Resolve host profile - prefer injected specialArg, fall back to config
  resolvedHostProfile = if hostProfile != null then hostProfile else config.profile.host;

  # Derive effective hostname (use alias if set, otherwise hostName)
  effectiveHostName =
    if
      (
        resolvedHostProfile ? hostAlias
        && resolvedHostProfile.hostAlias != null
        && resolvedHostProfile.hostAlias != ""
      )
    then
      resolvedHostProfile.hostAlias
    else
      resolvedHostProfile.hostName;

  # Generate unique host byte from hostname hash (matching actual Lima VM MACs)
  # Use single byte that matches the existing Lima VM interface MACs
  hostByteHex =
    let
      hash = builtins.hashString "sha256" effectiveHostName;
      # Take first 2 hex chars from hash - matches existing Lima VM: 27 for bioskop
    in
    lib.strings.toLower (builtins.substring 0 2 hash);

in
{
  options.lima.networkInterfaces = {
    enable = mkOption {
      type = types.bool;
      default = config.limaHost.isGuest;
      description = "Enable Lima network interface naming based on MAC addresses.";
    };

    interfaces = mkOption {
      type = types.listOf (
        types.submodule {
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
        }
      );
      default = [
        {
          macAddress = "52:55:55:da:5c:19"; # Lima primary implicit NIC (stable unless VM is recreated)
          name = "mgmt0"; # rename from enp0s1; update MAC if the Lima VM is rebuilt
        }
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:01";
          name = "vmlan0"; # lima vmnet bridged (for Incus lan-br bridge member)
        }
      ]
      ++ lib.optionals includeHostAndNatInterfaces [
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:00";
          name = "vznat0"; # lima vzNAT
        }
        {
          macAddress = "10:66:6a:4c:${hostByteHex}:02";
          name = "vmhost0"; # socket_vmnet shared network (host/NFS services)
        }
      ];
      description = ''
        List of network interfaces to rename based on MAC addresses.
        MAC addresses match the actual Lima VM interface MACs.
        Default mapping (for hostname 'bioskop' -> hash '27'):
        - 52:55:55:da:5c:19 -> mgmt0 (implicit primary Lima NIC; update if VM is rebuilt)
        - 10:66:6a:4c:27:00 -> vznat0 (Lima vzNAT management)
        - 10:66:6a:4c:27:01 -> vmlan0 (Incus lan-br bridge member for container LAN access)
        - 10:66:6a:4c:27:02 -> vmhost0 (socket_vmnet shared network for host/guest services)

        Scheme: OUI:LIMA:HOST:IF  
        - OUI: 10:66:6a (local/private)
        - LIMA: 0x4C (76, 'L' for Lima)
        - HOST: Hash-derived unique byte per Darwin host
        - IF: Interface index (00=vznat0, 01=vmlan0, 02=vmhost0)
      '';
    };
  };

  config = mkIf cfg.enable {
    # Use systemd-networkd for predictable interface naming (rename only)
    systemd.network.enable = lib.mkDefault true;
    # Avoid mixed network managers: with systemd.network enabled, keep legacy
    # interface-level DHCP scripting disabled unless a profile explicitly opts in.
    networking.useDHCP = lib.mkDefault false;

    # Disable wait-online: we only rename interfaces; they may be configured by other mechanisms (e.g. kernel/Lima DHCP)
    # Prevents 120s timeout because links are 'not managed by networkd'. If later you add .network files, remove this.
    systemd.network.wait-online.enable = false;

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
            MACAddressPolicy = "persistent"; # preserve MAC (no randomization)
          };
        };
      }) cfg.interfaces
    );

    # Pin the socket_vmnet backchannel to a static address with no default route
    # to avoid accidental gateway selection from DHCP on the shared network.
    # Update Address if you change the vmhost0 assignment.
    systemd.network.networks."40-vmhost0" = lib.mkIf includeHostAndNatInterfaces {
      matchConfig.Name = "vmhost0";
      networkConfig = {
        DHCP = "no";
        Address = [ "10.80.16.10/24" ];
        DNSDefaultRoute = false;
        Domains = [ "" ];
      };
      linkConfig = {
        RequiredForOnline = false;
      };
    };

    # Ensure only lan-br provides DNS for .lan and prevent other links from injecting DNS
    systemd.network.networks."40-lan-br" = {
      matchConfig.Name = "lan-br";
      networkConfig = {
        DNS = [ "192.168.1.254" ];
        Domains = [ "~lan" ];
      };
      dhcpV4Config.UseDNS = false;
    };

    systemd.network.networks."40-mgmt0" = {
      matchConfig.Name = "mgmt0"; # if renamed from enp0s1; adjust if not using rename
      networkConfig = {
        DHCP = "ipv4";
        Domains = [ "" ];
      };
      dhcpV4Config = {
        UseDNS = false;
        # Keep default route available as backup only.
        RouteMetric = 2000;
      };
    };

    # Fallback for rebuilt Lima VMs where the implicit primary NIC did not get
    # renamed to mgmt0 (e.g. MAC drift). Keep SSH management path alive.
    systemd.network.networks."40-enp0s1-fallback" = {
      matchConfig.Name = "enp0s1";
      networkConfig = {
        DHCP = "ipv4";
        Domains = [ "" ];
      };
      dhcpV4Config = {
        UseDNS = false;
        # Match mgmt0 policy in fallback mode.
        RouteMetric = 2000;
      };
      linkConfig = {
        RequiredForOnline = false;
      };
    };

    systemd.network.networks."40-vznat0" = lib.mkIf includeHostAndNatInterfaces {
      matchConfig.Name = "vznat0";
      networkConfig = {
        DHCP = "ipv4";
        Domains = [ "" ];
      };
      dhcpV4Config = {
        UseDNS = false;
        # Keep gateway but de-prioritize versus bridged LAN.
        RouteMetric = 3000;
      };
    };

    systemd.network.networks."40-vmlan0" = {
      matchConfig.Name = "vmlan0";
      networkConfig = {
        DHCP = "ipv4";
        Domains = [ "" ];
      };
      dhcpV4Config = {
        UseDNS = false;
        # Preferred default egress path (non-NAT bridged LAN).
        RouteMetric = 100;
      };
    };

    # Tart provider fallback: interface naming may vary (e.g. enp0s2/enp1s0)
    # if MAC-based renaming does not apply. Ensure at least one uplink gets DHCP.
    systemd.network.networks."40-tart-en-fallback" = lib.mkIf isTartProvider {
      matchConfig.Name = "en*";
      networkConfig = {
        DHCP = "ipv4";
        Domains = [ "" ];
      };
      dhcpV4Config = {
        UseDNS = false;
        RouteMetric = 500;
      };
      linkConfig = {
        RequiredForOnline = false;
      };
    };

    systemd.network.networks."40-tart-eth-fallback" = lib.mkIf isTartProvider {
      matchConfig.Name = "eth*";
      networkConfig = {
        DHCP = "ipv4";
        Domains = [ "" ];
      };
      dhcpV4Config = {
        UseDNS = false;
        RouteMetric = 500;
      };
      linkConfig = {
        RequiredForOnline = false;
      };
    };

    # Enable mDNS (Avahi) and bind it to lan-br and vmhost0 so host backchannel
    # mDNS works without leaking onto other links.
    services.avahi = {
      enable = true;
      nssmdns4 = true;
      allowInterfaces = [
        "lan-br"
      ]
      ++ lib.optionals includeHostAndNatInterfaces [ "vmhost0" ]
      ++ lib.optional vlanEnabled vlanName;
      publish = {
        enable = true;
        addresses = true;
        workstation = true;
        hinfo = true;
      };
    };

    # Note: vmlan0 bridge membership is configured in incus.nix

    # Helpful environment variables
    environment.variables = {
      LIMA_BRIDGE_IFACE = "vmlan0"; # Incus lan-br bridge member (unmanaged by NetworkManager)
      # Note: Lima VM SSH management uses enp0s1 (built-in), not vmlan0
    };
  };
}
