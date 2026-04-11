{ config, lib, ... }:
let
  cfg = config.nxmatic.etcBackup;
  etcTargets = builtins.attrNames config.environment.etc;
  etcBackupLib = import ../.common.d/etc-backup-lib.nix { inherit lib; };
  backupScript = etcBackupLib.mkEtcBackupScript {
    inherit etcTargets;
    extension = cfg.extension;
    overwrite = cfg.overwrite;
    moveConflicts = true;
  };
in
{
  options.nxmatic.etcBackup = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Back up existing /etc targets before NixOS etc activation.";
    };

    extension = lib.mkOption {
      type = lib.types.str;
      default = "nix-backup";
      description = "Backup extension appended to /etc paths when preserving conflicts.";
    };

    overwrite = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Overwrite existing backup files before writing a new backup.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.nxmaticEtcBackup = {
      deps = [ "specialfs" ];
      supportsDryActivation = false;
      text = backupScript;
    };
  };
}
