{
  config,
  lib,
  pkgs,
  ...
}:
# A launchd service that reads a sops secret once, at start, keeps the old value after a switch that
# rotates it: the plists did not change, so nix-darwin reloads nothing, and sops-nix has no
# restartUnits on darwin. Each such reader declares itself here, and after the install and every
# reader step, the services whose secret changed are kickstarted.
let
  cfg = config.ndh.restartOnSecretChange;
  restart = pkgs.writeShellApplication {
    name = "restart-on-secret-change";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.diffutils
    ];
    text = builtins.readFile ./restart-on-secret-change.d/restart-on-secret-change.sh;
  };
  manifest = pkgs.writeText "restart-on-secret-change.tsv" (
    lib.concatStrings (
      lib.mapAttrsToList (
        label: s: "${s.domain}\t${label}\t${s.reason}\t${lib.concatStringsSep " " s.secrets}\n"
      ) cfg
    )
  );
in
{
  options.ndh.restartOnSecretChange = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule {
        options = {
          domain = lib.mkOption {
            type = lib.types.str;
            description = "`system`, or `gui:<user>` for a user agent.";
          };
          secrets = lib.mkOption {
            type = lib.types.nonEmptyListOf lib.types.str;
            description = "Names of the sops.secrets entries the service reads at start.";
          };
          reason = lib.mkOption {
            type = lib.types.str;
            description = "What the activation output says before restarting it.";
          };
        };
      }
    );
    default = { };
    description = "launchd services (by label) restarted when a sops secret they read at start changes.";
  };

  config = lib.mkIf (cfg != { }) {
    assertions = lib.concatLists (
      lib.mapAttrsToList (
        label: s:
        map (secret: {
          assertion = config.sops.secrets ? ${secret};
          message = "ndh.restartOnSecretChange.${label} names ${secret}, which is not a sops secret.";
        }) s.secrets
      ) cfg
    );
    # The previous generation is what a change is measured against.
    sops.keepGenerations = 2;
    system.activationScripts.postActivation.text = lib.mkOrder config.ndh.darwin.postActivationOrder.restartSecretReaders ''
      ${restart}/bin/restart-on-secret-change /run/secrets ${manifest}
    '';
  };
}
