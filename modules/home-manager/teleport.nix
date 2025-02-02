{ config, pkgs, ... }: let
  nodeName = "pfouh";
  homeDir = "${config.home.homeDirectory}";
  dataDir = "${homeDir}/.local/var/teleport";
  xdgConfigFile = "${homeDir}/.config/teleport/teleport.yaml";

  teleportConfigFile = pkgs.writeText "teleport.yaml" ''
    version: v3
    teleport:
      nodename: ${nodeName}
      data_dir: ${dataDir}
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

  xdg.configFile."teleport" = {
    source = teleportConfigFile;
    recursive = false;
  };

  launchd.agents.teleport = {
    enable = true;
    config = {
      Label = "org.nix-community.home.teleport";
      ProgramArguments = [
        "${pkgs.teleport}/bin/teleport"
        "start"
        "--config"
        xdgConfigFile
      ];
      KeepAlive = true;
      RunAtLoad = true;
    };
  };

}

