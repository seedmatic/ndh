{
  config,
  lib,
  pkgs,
  catalog,
  ...
}:
# ndh-keyring on the operator seat's PATH: the operator generates the machines' host keys into their keyring.
# A gesture, never run by the activation.
{
  options.ndh.keyring.enable = lib.mkEnableOption "ndh-keyring on this operator seat (the one holding the keyring)";

  config = lib.mkIf config.ndh.keyring.enable {
    environment.systemPackages = [
      (import ../.common.d/keyring.d/package.nix {
        inherit pkgs lib;
        netplan = catalog.netplan;
      })
    ];
  };
}
