{ config, lib, ... }:
let
  cfg = config.ndh.darwinEtcBackup;
  etcTargets = builtins.attrNames config.environment.etc;
  etcBackupLib = import ../.common.d/etc-backup-lib.nix { inherit lib; };
  backupScript = etcBackupLib.mkEtcBackupScript {
    inherit etcTargets;
    extension = cfg.extension;
    overwrite = cfg.overwrite;
    managedPrefixes = [
      "/etc/static/"
      "/nix/store/"
    ];
    moveConflicts = true;
  };
in
{
  options.ndh.darwinEtcBackup = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Back up conflicting /etc targets before nix-darwin etc reconciliation.";
    };

    extension = lib.mkOption {
      type = lib.types.str;
      default = "before-nix-darwin";
      description = "Backup extension appended to conflicting /etc paths.";
    };

    overwrite = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Overwrite existing backup files before writing a new backup.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.preActivation.text = lib.mkOrder 5 backupScript;
  };
}
