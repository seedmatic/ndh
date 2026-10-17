{
  config,
  lib,
  pkgs,
  ...
}:
# ndh-switch on the operator seat's PATH: the one switch verb the sessions may run (the managed list denies the raw
# rebuilds), so 🎛️ operations switches the fleet by a pushed, merged revision while the operator is away.
let
  cfg = config.ndh.ndhSwitch;
in
{
  options.ndh.ndhSwitch = {
    enable = lib.mkEnableOption "ndh-switch, the sessions' switch verb, on this operator seat";
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/ndh-switch.d/package.nix {
        inherit pkgs;
        seat = config.networking.hostName;
      };
      description = "ndh-switch, built for this seat: it refuses to run from any other.";
    };
    fleetSwitch = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = import ../.common.d/fleet-switch.d/package.nix {
        inherit pkgs;
        ndhSwitch = cfg.package;
      };
      description = "fleet-switch, the ordered loop over this seat's ndh-switch.";
    };
  };

  config = lib.mkIf cfg.enable {
    environment.systemPackages = [
      cfg.package
      cfg.fleetSwitch
    ];
  };
}
