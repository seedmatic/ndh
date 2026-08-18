{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:

let
  cfg = config.networking.lanDnsResolver;
  ndhContext = ndh.context;
  # Single source: LAN gateway + domain from the catalog feed the option
  # defaults, so a host never re-types them.  `domain` is the dotted `.lan`;
  # the scoped resolver filename and search domain want the bare label.
  lan = ndhContext.catalog.netplan.lan;
  lanDomain = lib.removePrefix "." lan.domain;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  lanDnsActivationScript = ndh.store.installScript {
    name = "lan-dns-resolver-post-activation.sh";
    source = pkgs.replaceVars ./lan-dns-resolver.d/post-activation.sh {
      nixBashTrampoline = nixBashTrampoline;
      inherit (cfg) nameserver;
    };
    preferLocalBuild = true;
    allowSubstitutes = false;
    mode = "0755";
  };

in
{
  options.networking.lanDnsResolver = {
    enable = lib.mkEnableOption "Enable .lan domain DNS resolver configuration";

    nameserver = lib.mkOption {
      type = lib.types.str;
      default = lan.gateway;
      description = "DNS server to use for .lan domain resolution";
    };

    searchDomains = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [ lanDomain ];
      description = "Search domains for .lan resolver";
    };
  };

  config = lib.mkIf cfg.enable {
    # Create resolver configuration for .lan domain
    # macOS uses /etc/resolver/<domain> files for domain-specific DNS resolution
    environment.etc."resolver/${lanDomain}" = {
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
