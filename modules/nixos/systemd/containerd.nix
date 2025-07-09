{ config, pkgs, profile, ... }:

{
  virtualisation.containerd.enable = true;

  environment.systemPackages = with pkgs; [ iptables runc ];
 
  # Optional: For rootless or special socket permissions, see notes below.
  # services.containerd.extraArgs = "--address /run/containerd/containerd.sock";

  # Add your user to the containerd group for socket access
  users.groups.containerd = { };
  users.groups.nixos = { };
  users.users.${profile.user.name}.extraGroups = [ "wheel" "containerd" "nixos" ];
}
