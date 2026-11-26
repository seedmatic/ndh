{
  config,
  lib,
  pkgs,
  ...
}:
let
  omoPatch = import ./omo-patch.d/package.nix { inherit pkgs; };
  cfg = config.ndh.omoPatch;
in
{
  options.ndh.omoPatch = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable omo-patch home-manager integration (manual trigger by default).";
    };
    profile = lib.mkOption {
      type = lib.types.nullOr lib.types.str;
      default = null;
      description = "Profile to apply via omo-patch.";
    };
    package = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      default = omoPatch;
      description = "The omo-patch package.";
    };
  };

  config = lib.mkIf cfg.enable {
    home.packages = [ omoPatch ];
    home.activation.omoPatch = lib.mkIf (cfg.profile != null) (
      lib.hm.dag.entryAfter [ "writeBoundary" ] ''
        run ${omoPatch}/bin/omo-patch --profile ${lib.escapeShellArg cfg.profile}
      ''
    );
  };
}
