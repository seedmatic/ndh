# Custom socket_vmnet configuration values
# The options are defined by the external socket-vmnet flake module
# imported at the flake level in preModules
{ config, pkgs, lib, ... }:

{
  config = {
    services.socket_vmnet.enable = true;
    services.socket_vmnet.dataDir = "${config.profile.user.home}/.local/share/nxmatic";
    services.socket_vmnet.lanInterface = "en0";
    services.socket_vmnet.wanGateway = "10.80.16.1";
    services.socket_vmnet.wanSubnet = "10.80.16.0/24";
  };
}
