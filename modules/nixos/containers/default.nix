{
  config,
  pkgs,
  lib,
  paths,
  containerRegistrySystem,
  ...
}:
{
  imports = [
    (import ./ctreg.nix {
      inherit
        config
        pkgs
        lib
        paths
        containerRegistrySystem
        ;
    })
  ];
}
