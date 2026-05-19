{
  config,
  pkgs,
  lib,
  worktreePath,
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
        worktreePath
        containerRegistrySystem
        ;
    })
  ];
}
