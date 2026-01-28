{
  config,
  lib,
  pkgs,
  ...
}:

let
  cfg = config.networking.lanDnsResolver;
  lanDnsActivationScript =
    pkgs.runCommand "lan-dns-resolver-post-activation.sh"
      {
        preferLocalBuild = true;
        allowSubstitutes = false;
      }
      ''
        install -Dm755 ${
          pkgs.replaceVars ./lan-dns-resolver.d/post-activation.sh {
            inherit (cfg) nameserver;
            activationLogger = lib.attrByPath [
              "activation"
              "loggerScript"
            ] ../common/activation-logger.sh config;
          }
        } "$out"
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
    system.activationScripts.networking.text = lib.mkAfter ''
      ${lanDnsActivationScript}
    '';
  };
}
