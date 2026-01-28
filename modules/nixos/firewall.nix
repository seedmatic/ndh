{ config, lib, ... }:
{
  # Base firewall configuration for NixOS host
  # This applies to the host level, not individual Incus instances
  # Note: remote-builder.nix has its own separate firewall config (dedicated VM)
  #
  # Individual modules (caddy.nix, podman.nix, incus.nix, tailscale.nix, networking-mammoth-skate.nix)
  # contribute their own ports and trusted interfaces, which are merged with this base config.

  networking.firewall = {
    enable = true;
    logRefusedPackets = true;
    allowedTCPPorts = [
      22
      53
      80
      443
      2222
      2375
      5002
      8090
      8095
      8098
      9200
      9600
      27017
      4566
      5601
    ];
  };
}
