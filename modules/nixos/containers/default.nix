{ config, pkgs, lib, containerRegistrySystem, ... }: {
  imports = [
    (import ./ctreg.nix { inherit config pkgs lib containerRegistrySystem; })
  ];
}
