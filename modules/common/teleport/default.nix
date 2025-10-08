{ config, lib, pkgs, ... }:

# Teleport common modules - RBAC roles and helper scripts
# These are available on both Darwin and NixOS systems

{
  imports = [
    ./roles.nix
    ./setup.nix
  ];
}
