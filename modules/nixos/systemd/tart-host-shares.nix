{
  config,
  lib,
  ...
}:

let
  isTartProvider = config.ndh.vm.provider == "tart";
in
{
  options.ndh.vm.tart.hostShares.sopsAge = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        Mount host-provided SOPS age key share for Tart guests.
      '';
    };

    mountTag = lib.mkOption {
      type = lib.types.str;
      default = "ndh-sops-age";
      description = ''
        Virtiofs tag used by Tart `--dir ...:tag=<tag>` for SOPS age key share.
      '';
    };

    expectedRunTag = lib.mkOption {
      type = lib.types.str;
      default = "ndh-sops-age";
      description = ''
        Expected Tart run share tag for the host SOPS age directory.
        Keep this aligned with `tart.configGenerator.vmRunSopsAgeTag`.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = "/mnt/tart-cidata/.sops.d";
      description = ''
        Guest mount point containing host-provided `keys.txt` for SOPS bootstrap import.
      '';
    };
  };

  config = lib.mkIf (isTartProvider && config.ndh.vm.tart.hostShares.sopsAge.enable) {
    assertions = [
      {
        assertion =
          config.ndh.vm.tart.hostShares.sopsAge.mountTag
          == config.ndh.vm.tart.hostShares.sopsAge.expectedRunTag;
        message = ''
          ndh.vm.tart.hostShares.sopsAge.mountTag must match ndh.vm.tart.hostShares.sopsAge.expectedRunTag.
          This guards against host/guest Tart SOPS share tag drift. Also keep it aligned with
          tart.configGenerator.vmRunSopsAgeTag on the host.
        '';
      }
    ];

    systemd.tmpfiles.rules = [
      "d /mnt/tart-cidata 0755 root root -"
    ];

    fileSystems."${config.ndh.vm.tart.hostShares.sopsAge.mountPoint}" = {
      device = config.ndh.vm.tart.hostShares.sopsAge.mountTag;
      fsType = "virtiofs";
      options = [
        "ro"
        "nofail"
      ];
    };
  };
}
