# Run dnsmasq on the tailnet interface to serve CNAME records for
# structured service names under mammoth-skate.ts.net.
#
# Runs as a LaunchDaemon (system-level, root) so it can bind to port 53
# on the tailnet interface. Headscale advertises this host's tailnet IP
# as a nameserver, and DNS clients query it on the standard port.
#
# Architecture:
#   - MagicDNS provides base records: bioskop.mammoth-skate.ts.net → 100.64.0.1
#   - This dnsmasq provides CNAMEs: rdp.bioskop.mammoth-skate.ts.net → bioskop.mammoth-skate.ts.net
#   - Headscale advertises this host's tailnet IP as a nameserver
#   - Queries flow: MagicDNS → this dnsmasq → upstream
{
  config,
  pkgs,
  lib,
  ...
}:
let
  cfg = config.networking.dnsZoneMammothSkateTailnet;
  hostName = config.networking.hostName or "localhost";

  # Derive the listen IP from the catalog-defined tailnet mapping.
  # Each host has a known sequential IP in the tailnet CIDR.
  # bioskop = 100.64.0.1, nikopol = 100.64.0.2
  # This matches the IPs headscale assigns from prefixes.v4 in the daemon config.
  hostToTailnetIp = {
    bioskop = "100.64.0.1";
    nikopol = "100.64.0.2";
  };
  tailnetIp = hostToTailnetIp.${hostName} or "127.0.0.1";
in
{
  config = lib.mkIf cfg.enable {
    # Run as LaunchDaemon (not LaunchAgent) so it can bind to port 53.
    # The LAN dnsmasq (mammoth-skate.test) stays as LaunchAgent on port
    # 5354 because /etc/resolver can specify custom ports, but headscale's
    # nameserver list only supports standard port 53.
    launchd.daemons.dnsmasq-tailnet = {
      serviceConfig = {
        Label = "io.nxmatic.nix-darwin-home.darwin.dnsmasq-tailnet";
        ProgramArguments = [
          "${pkgs.dnsmasq}/bin/dnsmasq"
          "--conf-file=/etc/dnsmasq-tailnet.conf"
          "--keep-in-foreground"
        ];
        RunAtLoad = true;
        KeepAlive = true;
        WatchPaths = [ "/etc/dnsmasq-tailnet.conf" ];
      };
    };

    environment.etc."dnsmasq-tailnet.conf".text = ''
      # Listen on tailnet interface at this host's assigned tailnet IP
      # Port 53 (standard DNS) - requires root, hence LaunchDaemon
      listen-address=${tailnetIp}
      port=53

      # Don't read /etc/resolv.conf
      no-resolv

      # Forward to upstream DNS (public resolvers)
      # MagicDNS queries are handled by tailscaled directly, not via DNS forwarding
      server=1.1.1.1
      server=8.8.8.8

      # CNAME records for this host's structured service names.
      # These expand to the MagicDNS name, which tailscaled will resolve.
      # Example: rdp.bioskop.mammoth-skate.ts.net → bioskop.mammoth-skate.ts.net → 100.64.0.1
      ${cfg.dnsmasqSnippet}

      # Enable logging
      log-queries
    '';
  };
}
