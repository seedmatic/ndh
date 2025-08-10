{ profile, config, lib, pkgs, self, ... }: {
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./dnsmasq.nix
    ./lima-config.nix
    ./linux-builder.nix
    ./distributed-builds.nix
    ./podman-remote-client.nix
    ./raycast.nix
    ./ssh.nix
  # Inline module replaced with file import for Home Manager extension
  ./extend-hm-imports.nix
  ];
}
