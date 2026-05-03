{
  config,
  lib,
  ndh,
  ...
}:

let
  isTartProvider = config.ndh.vm.provider == "tart";
  ndhContext = ndh.context;
  srvHostRoot = "/srv/host";
  sopsAgeMountPointDefault = "${srvHostRoot}/sops.d";
  generationMode = ndhContext.generationMode;
  bringupMode = generationMode == "bringup";
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
        Keep this aligned with the host Tart run wrapper configuration when
        host-share mode is intentionally enabled.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = sopsAgeMountPointDefault;
      description = ''
        Guest mount point containing host-provided `keys.txt` for SOPS bootstrap import.
      '';
    };
  };

  config = lib.mkIf isTartProvider (
    lib.mkMerge [
      {
        systemd.tmpfiles.rules = [
          "d ${srvHostRoot} 0755 root root -"
        ];
      }

      (lib.mkIf config.ndh.vm.tart.hostShares.sopsAge.enable {
        assertions = [
          {
            assertion =
              config.ndh.vm.tart.hostShares.sopsAge.mountTag
              == config.ndh.vm.tart.hostShares.sopsAge.expectedRunTag;
            message = ''
              ndh.vm.tart.hostShares.sopsAge.mountTag must match ndh.vm.tart.hostShares.sopsAge.expectedRunTag.
              This guards against host/guest Tart SOPS share tag drift when host-share mode is enabled.
            '';
          }
        ];

        # Tart exposes host directories via virtio-fs; load the kernel module so
        # the mount unit succeeds early in boot (before sops-age-bootstrap runs).
        boot.kernelModules = [ "virtiofs" ];

        fileSystems."${config.ndh.vm.tart.hostShares.sopsAge.mountPoint}" = {
          device = config.ndh.vm.tart.hostShares.sopsAge.mountTag;
          fsType = "virtiofs";
          options = [
            "ro"
            "nofail"
          ];
        };
      })
    ]
  );
}
