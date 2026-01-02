{ config, pkgs, ... }:
{
  config = {
    networking.firewall.allowedTCPPorts = [
      80
      443
    ];

    systemd.services.tailscaled.environment = {
      TS_PERMIT_CERT_UID = "caddy";
    };

    services.caddy = {
      enable = true;
      logDir = "/var/log/caddy";
      virtualHosts = {
        "${config.networking.hostName}.${config.containerHost.domainName}" = {
          serverAliases = [ "${config.networking.hostName}" ];
          extraConfig = ''
            reverse_proxy 127.0.0.1:5000
              tls {
                get_certificate tailscale
              }
          '';
        };
      };
    };

  };
}
