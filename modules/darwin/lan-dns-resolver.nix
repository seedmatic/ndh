{ config, lib, pkgs, ... }:

let
  cfg = config.networking.lanDnsResolver;
in
{
  options.networking.lanDnsResolver = {
    enable = lib.mkEnableOption "Enable .lan domain DNS resolver configuration";
    
    nameserver = lib.mkOption {
      type = lib.types.str;
      default = "192.168.1.254";
      description = "DNS server to use for .lan domain resolution";
    };
    
    searchDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ "lan" ];
      description = "Search domains for .lan resolver";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create resolver configuration for .lan domain
    # macOS uses /etc/resolver/<domain> files for domain-specific DNS resolution
    environment.etc."resolver/lan" = {
      text = ''
        # DNS resolver configuration for .lan domain
        # This file configures macOS to use the local LAN DNS server
        # for resolving .lan domain names
        nameserver ${cfg.nameserver}
        ${lib.concatMapStringsSep "\n" (domain: "search_order 1") cfg.searchDomains}
      '';
    };

    # Also ensure the network interfaces are configured with the LAN DNS
    # This activation script runs after the main DNS configuration
    system.activationScripts.postActivation.text = lib.mkAfter ''
      : "Configure LAN DNS resolver for .lan domain"
      
      # Check if we're on a network that has the LAN gateway accessible
      if ping -c 1 -W 1 ${cfg.nameserver} >/dev/null 2>&1; then
        : "LAN gateway ${cfg.nameserver} is reachable, ensuring resolver is configured"
        
        # The /etc/resolver/lan file is already managed by nix-darwin
        # Just verify it exists
        if [ -f /etc/resolver/lan ]; then
          : "Resolver configuration for .lan domain is active"
        else
          : "Warning: /etc/resolver/lan file not found"
        fi
        
        # Flush DNS cache to pick up the new resolver configuration
        dscacheutil -flushcache
        killall -HUP mDNSResponder 2>/dev/null || true
      else
        : "LAN gateway ${cfg.nameserver} not reachable, skipping LAN DNS configuration"
      fi
    '';
  };
}
