# Custom socket_vmnet configuration values
# The options are defined by the external socket-vmnet flake module
# imported at the flake level in preModules
{
  config,
  pkgs,
  lib,
  ...
}:

{
  config = {
    services.socket_vmnet.enable = true;
    services.socket_vmnet.dataDir = "${config.profile.user.home}/.local/share/nxmatic";
    services.socket_vmnet.lanInterface = "en0";
  };
}
