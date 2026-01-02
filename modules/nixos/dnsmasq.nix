{ config, ... }:
let
  # Use vmlan0 interface in Lima guests, otherwise fall back to enp0s1
  primaryInterface = if config.limaHost.isGuest then "vmlan0" else "enp0s1";
in
{
  services.dnsmasq = {
    enable = false;
    settings = {
      interface = [ primaryInterface ];
      except-interface = [
        "internalbr0"
        "externalbr0"
      ];
    };
  };

  environment.etc."dnsmasq.conf".text = ''
    # Forward .internal queries to the custom DNS proxy
    server=/internal/127.0.0.1#5453

    # Use these for non-.internal domains
    server=100.100.100.100
    server=8.8.8.8
    server=8.8.4.4
    server=1.1.1.1

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
  '';

}
