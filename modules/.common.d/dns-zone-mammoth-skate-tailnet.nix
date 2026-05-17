# DNS zone for `mammoth-skate.ts.net` — tailnet-scoped CNAME records
# served by dnsmasq on each Darwin host's tailnet interface.
#
# Complements MagicDNS:
#   - MagicDNS provides:  bioskop.mammoth-skate.ts.net → 100.64.0.1
#   - This zone provides: rdp.bioskop.mammoth-skate.ts.net → CNAME to bioskop.mammoth-skate.ts.net
#
# Each host serves CNAMEs for its own structured names (rdp-host, vz-host, ssh-host)
# by running dnsmasq on its tailnet IP.  Headscale advertises all host tailnet IPs
# as nameservers, so queries fan out and each host answers for its own subdomains.
{
  config,
  lib,
  ndh ? null,
  ...
}:
let
  cfg = config.networking.dnsZoneMammothSkateTailnet;
  hostName = config.networking.hostName or "localhost";

  # Each host serves CNAMEs for its own structured service names.
  # Format: <service>.<hostname>.mammoth-skate.ts.net → CNAME to <hostname>.mammoth-skate.ts.net
  # MagicDNS already provides the A record for <hostname>.mammoth-skate.ts.net
  serviceAliases = [
    "rdp"
    "vz-host"
    "ssh-host"
  ];

  # Generate CNAME lines for dnsmasq config
  # Example: cname=rdp.bioskop.mammoth-skate.ts.net,bioskop.mammoth-skate.ts.net
  cnameLines = lib.concatMapStringsSep "\n" (service:
    "cname=${service}.${hostName}.mammoth-skate.ts.net,${hostName}.mammoth-skate.ts.net"
  ) serviceAliases;

  # Extra host-specific CNAMEs (e.g., headscale.bioskop.ts.net → bioskop.ts.net)
  extraCnameLines = lib.concatStringsSep "\n" (
    lib.mapAttrsToList (name: target:
      "cname=${name}.${hostName}.mammoth-skate.ts.net,${target}"
    ) cfg.extraCnames
  );

in
{
  options.networking.dnsZoneMammothSkateTailnet = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = config.networking.headscale.enable or false;
      description = ''
        Whether to serve tailnet-scoped CNAME records for this host's
        structured service names (rdp.*, vz-host.*, etc.) under
        mammoth-skate.ts.net.  Auto-enabled when headscale client is
        enabled.  Requires dnsmasq to be listening on the tailnet
        interface.
      '';
    };

    extraCnames = lib.mkOption {
      type = lib.types.attrsOf lib.types.str;
      default = {};
      example = {
        headscale = "bioskop.mammoth-skate.ts.net";
        api = "peer1.rke2.bioskop.mammoth-skate.ts.net";
      };
      description = ''
        Additional host-specific CNAME records to serve.  Keys are the
        subdomain names (without the host prefix), values are the CNAME
        targets.  Example: { headscale = "bioskop.mammoth-skate.ts.net"; }
        creates: headscale.bioskop.mammoth-skate.ts.net → bioskop.mammoth-skate.ts.net

        Use this for service-level routing that may change across phases:
        - Phase A (bootstrap): headscale → bioskop (Darwin LaunchAgent)
        - Phase B (cluster): headscale → rke2-ingress (K8s deployment)
      '';
    };

    dnsmasqSnippet = lib.mkOption {
      type = lib.types.str;
      internal = true;
      description = ''
        Dnsmasq configuration snippet for tailnet CNAMEs.  Consumed by
        modules/.common.d/dnsmasq-tailnet.nix which injects it into the
        dnsmasq config that listens on the tailnet interface.
      '';
    };
  };

  config = lib.mkIf cfg.enable {
    networking.dnsZoneMammothSkateTailnet.dnsmasqSnippet = ''
      # Tailnet CNAME records for ${hostName}
      # Standard service subdomains (rdp, vz-host, ssh-host)
      ${cnameLines}
      ${lib.optionalString (cfg.extraCnames != {}) ''

      # Host-specific service CNAMEs (configurable per-host)
      ${extraCnameLines}''}
    '';
  };
}
