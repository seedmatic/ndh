{ config, lib, ... }:
let
  cfg = config.services.nfsAutofs;

  autoMasterLines = [
    "${cfg.mountPoint} ${cfg.map} ${cfg.mapOptions}"
  ];

  autoMasterText = lib.concatStringsSep "\n" autoMasterLines + "\n";

in
{
  options.services.nfsAutofs = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable NFS client support with /net autofs map.";
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/net";
      description = "Mount point used for autofs host browsing.";
    };

    map = lib.mkOption {
      type = lib.types.str;
      default = "-hosts";
      description = "Autofs map used for on-demand host mounts.";
    };

    mapOptions = lib.mkOption {
      type = lib.types.str;
      default = "-soft,intr,nosuid";
      description = "Autofs options applied to the /net entry.";
    };

    timeout = lib.mkOption {
      type = lib.types.int;
      default = 300;
      description = "Autofs global timeout before idle mounts are dropped (seconds).";
    };

  };

  config = lib.mkIf cfg.enable {
    boot.supportedFilesystems.nfs = true;
    boot.supportedFilesystems.nfs4 = true;

    services.autofs = {
      enable = true;
      timeout = cfg.timeout;
      autoMaster = autoMasterText;
    };
  };
}
