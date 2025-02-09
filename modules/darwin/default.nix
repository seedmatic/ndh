{ ... }:
{
  imports = [
    ../common
    ./preferences.nix
    ./security.nix
    ./core.nix
    ./environment.nix

    ./linux-builder.nix
    ./raycast.nix
    ./ssh.nix
  ];
}