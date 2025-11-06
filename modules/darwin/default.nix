{ profile, config, lib, pkgs, self, ... }: {
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./dnsmasq.nix
    ./headscale-client.nix
    ./internet-sharing.nix
    ./lima-config.nix
    ./linux-builder.nix
    ./distributed-builds.nix
    ./podman-remote-client.nix
    ./raycast.nix
    # ./socket_vmnet.nix
    ./openssh.nix
    ./github-mcp-proxy.nix
    ./shell-keychain.nix
    ./ssh-client.nix
  ];
}
