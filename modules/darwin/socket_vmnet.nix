# Socket_vmnet configuration for Lima
# Lima requires socket_vmnet binaries at /opt/socket_vmnet (cannot use symlinks)
# Lima manages its own socket_vmnet instances:
#   /var/run/lima/socket_vmnet.shared (NAT mode - 172.16.105.x)
#   /var/run/lima/socket_vmnet.bridged (bridged mode - home LAN IPs)
#   /var/run/lima/socket_vmnet.host
# 
# Lima config uses vzNAT + bridged modes for dual network setup
{ pkgs, lib, ... }: {
  services = {
    socket_vmnet = {
      enable = true;
    };
  };

  # Copy socket_vmnet binaries to /opt/socket_vmnet for Lima
  # Lima cannot use symlinked binaries, so we copy the real files from nix store
  system.activationScripts.postActivation.text = 
    let
      socket_vmnet_pkg = pkgs.socket_vmnet or (throw "socket_vmnet package not found in pkgs");
      socket_vmnet_path = "${socket_vmnet_pkg}";
    in ''
      : "Setting up socket_vmnet for Lima..."
      
      mkdir -p /opt/socket_vmnet
      rsync -av --delete "${socket_vmnet_path}/" /opt/socket_vmnet/
    '';
}
