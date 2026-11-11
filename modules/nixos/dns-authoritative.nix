{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "mammoth-skate.fr.eu.org";
  ns1 = "mammoth-skate.duckdns.org";
  listenAddress = "192.168.1.130";
  afraidSecondaryIP = "69.65.50.223";

  zoneContent = ''
    $ORIGIN ${domain}.
    $TTL 3600
    @ IN SOA ${ns1}. hostmaster.${domain}. (
        2026111102 ; serial
        3600       ; refresh
        900        ; retry
        1209600    ; expire
        86400      ; minimum
    )
    @ IN NS ${ns1}.
    @ IN NS ns1.hostry.com.
    @ IN NS ns2.hostry.com.
    @ IN NS ns3.hostry.com.
    @ IN NS ns4.hostry.com.
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
      acl = [
        {
          id = "afraid-axfr";
          address = [ afraidSecondaryIP ];
          action = "transfer";
        }
        {
          id = "hostry-axfr";
          address = [
            "213.247.44.19"
            "204.155.151.229"
            "195.123.233.100"
            "45.32.157.198"
          ];
          action = "transfer";
        }
      ];
      template = [
        {
          id = "default";
          storage = "/var/lib/knot";
          file = zoneFile;
          acl = [
            "afraid-axfr"
            "hostry-axfr"
          ];
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
