{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "mammoth-skate.fr.eu.org";
  ns1 = "mammoth-skate.duckdns.org";
  # Knot binds only to the VM's bridged LAN IP to avoid clashing with
  # dnsmasq (which owns 127.0.0.1, 10.80.x.1, 172.16.x.1 on port 53).
  # Reserve this address in the Bbox DHCP for the VM's MAC.
  listenAddress = "192.168.1.130";

  zoneContent = ''
    $ORIGIN ${domain}.
    $TTL 3600
    @ IN SOA ${ns1}. hostmaster.${domain}. (
        2026111101 ; serial
        3600       ; refresh
        900        ; retry
        1209600    ; expire
        86400      ; minimum
    )
    @ IN NS ${ns1}.
    @ IN NS ns2.afraid.org.
  '';

  zoneFile = pkgs.writeText "${domain}.zone" zoneContent;
in
{
  services.knot = {
    enable = true;
    settings = {
      server = {
        listen = [ "${listenAddress}@53" ];
      };
      template = [
        {
          id = "default";
          storage = "/var/lib/knot";
          file = zoneFile;
        }
      ];
      zone = [
        {
          domain = domain;
          template = "default";
        }
      ];
    };
  };

  networking.firewall = {
    allowedUDPPorts = [ 53 ];
    allowedTCPPorts = [ 53 ];
  };
}
