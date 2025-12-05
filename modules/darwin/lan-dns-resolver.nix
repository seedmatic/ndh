{ config, lib, pkgs, ... }:

let
  cfg = config.networking.lanDnsResolver;

  lanDnsActivationScript = pkgs.writeShellScript "lan-dns-resolver-activation.sh" ''
    set -euo pipefail
    LOG="/var/log/darwin-lan-dns-resolver.log"
    {
      echo "[lanDns] Validating LAN resolver"

      if ping -c 1 -W 1 ${cfg.nameserver} >/dev/null 2>&1; then
        echo "[lanDns] Gateway ${cfg.nameserver} reachable; verifying resolver file"
        if [ -f /etc/resolver/lan ]; then
          echo "[lanDns] /etc/resolver/lan present"
        else
          echo "[lanDns][WARN] /etc/resolver/lan missing"
        fi
        dscacheutil -flushcache
        killall -HUP mDNSResponder 2>/dev/null || true
      else
        echo "[lanDns] Gateway ${cfg.nameserver} unreachable; skipping resolver refresh"
      fi
    } >>"$LOG" 2>&1
  '';
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
      ${lanDnsActivationScript}
    '';
  };
}
