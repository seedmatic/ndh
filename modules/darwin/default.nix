{ profile, config, lib, pkgs, self, ... }: {
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./dnsmasq.nix
    ./linux-builder.nix
    ./raycast.nix
    ./ssh.nix
  # Inline module replaced with file import for Home Manager extension
  ./extend-hm-imports.nix
  ];
}
