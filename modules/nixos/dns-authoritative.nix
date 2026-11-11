{
  config,
  lib,
  pkgs,
  ...
}:

let
  domain = "mammoth-skate.fr.eu.org";
  ns1 = "mammoth-skate.duckdns.org";

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
        listen = [ "0.0.0.0@53" ];
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
