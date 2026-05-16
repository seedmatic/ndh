{
  config,
  lib,
  ...
}:
let
  dnsZoneCfg = config.networking.dnsZoneMammothSkateTest;
  dnsZoneSnippet = lib.optionalString dnsZoneCfg.enable dnsZoneCfg.dnsmasqSnippet;
in
{

  environment.etc."dnsmasq.conf".text = ''
    # Forward .internal queries to the custom DNS proxy
    server=/internal/127.0.0.1#5453

    # Optional: Use these for non-.internal domains
    server=8.8.8.8
    server=8.8.4.4

    # Listen on localhost
    listen-address=127.0.0.1
    port=53

    # Don't use /etc/resolv.conf
    no-resolv

    # Enable logging
    log-queries

    # Increase logging verbosity
    log-debug

    # Increase forwarding timeout (default is 5 seconds)
    dns-forward-max=150
    # query-timeout=10
    ${dnsZoneSnippet}
  '';

}
