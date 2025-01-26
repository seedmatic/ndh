{ config, pkgs, lib, ... }: let
  teleportConfigFile = pkgs.writeText "teleport.yaml" ''
    version: v3
    teleport:
      nodename: ${config.user.name}
      data_dir: ~/.local/var/teleport
      log:
        output: stderr
        severity: INFO
        format:
          output: text
      ca_pin: ""
      diag_addr: ""
    auth_service:
      enabled: "yes"
      listen_addr: 0.0.0.0:3025
      cluster_name: nxmatic
      proxy_listener_mode: multiplex
    ssh_service:
      enabled: "yes"
    proxy_service:
      enabled: "yes"
      web_listen_addr: 0.0.0.0:443
      public_addr: nxmatic:443
      https_keypairs: []
      https_keypairs_reload_interval: 0s
      acme:
        enabled: "yes"
        email: "stephane.lacoin:teleport@gmail.com"
  '';
in
{

  xdg.configFile  = {
    "teleport" = {
      source = teleportConfigFile;
      recursive = false;
    };
  };

  home.packages = [ pkgs.teleport ];

  launchd.daemons.teleport = {
    serviceConfig = {
      Label = "teleport";
      ProgramArguments = [
        "${pkgs.teleport}/bin/teleport"
        "start"
        "--config"
        "${teleportConfigFile}"
      ];
      KeepAlive = true;
      RunAtLoad = true;
      StandardOutPath = "/var/log/teleport.log";
      StandardErrorPath = "/var/log/teleport.error.log";
    };
  };

}

