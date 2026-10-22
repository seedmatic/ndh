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
  options.ndh.keyring = {
    enable = lib.mkEnableOption "ndh-keyring on this operator seat (the one holding the keyring)";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/keyring.d/package.nix {
        inherit pkgs lib;
        netplan = catalog.netplan;
      };
      description = "ndh-keyring, built for this seat: on its PATH when enabled, and one of ndh-ops's tools.";
    };
  };

  config = lib.mkIf config.ndh.keyring.enable {
    environment.systemPackages = [ config.ndh.keyring.package ];
  };
}
