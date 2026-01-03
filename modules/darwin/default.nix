{
  profile,
  config,
  lib,
  pkgs,
  self,
  ...
}:
{
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./disable-google-updaters.nix
    ./dnsmasq.nix
    ./headscale-client.nix
    ./internet-sharing.nix
    ./lan-dns-resolver.nix
    ./nfs-autofs.nix
    ./lima-config.nix
    ./linux-builder.nix
    ./distributed-builds.nix
    ./network-bond.nix
    ./podman-remote-client.nix
    ./raycast.nix
    # ./socket_vmnet.nix
    ./openssh.nix
    ./github-mcp-proxy.nix
    ./shell-keychain.nix
    ./ssh-client.nix
  ];

  activation.loggerCmd = lib.mkDefault "/usr/bin/logger -p notice -t %TAG%";
}
