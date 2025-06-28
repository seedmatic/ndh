{ ... }:
{
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix

    ./linux-builder.nix
    ./raycast.nix
    ./ssh.nix
  ];
}