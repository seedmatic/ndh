# Home Manager socket_vmnet configuration
# Provides XDG-compliant directories and configuration for custom socket_vmnet services
{ config, pkgs, lib, socket_vmnet,... }:

with lib;

let
  cfg = config.services.socket-vmnet;
in {
  options.services.socket-vmnet = {
    enable = mkOption {
      type = types.bool;
      default = true;
      description = "Enable socket_vmnet configuration in XDG directories";
    };
    
    dataDir = mkOption {
      type = types.str;
      default = "${config.xdg.dataHome}/nxmatic";
      description = "Directory for socket_vmnet sockets and logs";
    };
  };

  config = mkIf cfg.enable {
    # Ensure XDG directories are created
    xdg.dataFile."nxmatic/.keep" = {
      text = "";
    };

    # Set up environment variables for socket paths (useful for scripts)
    home.sessionVariables = {
      SOCKET_VMNET_LAN = "${cfg.dataDir}/lan.sock";
      SOCKET_VMNET_WAN = "${cfg.dataDir}/wan.sock";
      SOCKET_VMNET_DATA_DIR = cfg.dataDir;
    };
  };
}