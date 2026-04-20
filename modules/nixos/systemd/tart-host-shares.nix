{
  config,
  lib,
  ndh,
  ...
}:

let
  isTartProvider = config.ndh.vm.provider == "tart";
  ndhContext = ndh.context;
  ndhRuntimeRoot = "/run/ndh";
  tartCiDataRoot = "/mnt/tart-cidata";
  sopsAgeMountPointDefault = "${tartCiDataRoot}/.sops.d";
  ndhHostSharesRoot = "${ndhRuntimeRoot}/host-shares";
  ndhTopLevelMountPointDefault = "${ndhHostSharesRoot}/ndh-top-level";
  generationMode = ndhContext.generationMode;
  bringupMode = generationMode == "bringup";
  ndhTopLevelShareEnabled = config.ndh.vm.tart.hostShares.ndhTopLevel.enable;
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

  options.ndh.vm.tart.hostShares.ndhTopLevel = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = bringupMode;
      description = ''
        Mount host NDH repository top-level share for Tart bootstrap guests.
      '';
    };

    mountTag = lib.mkOption {
      type = lib.types.str;
      default = "ndh-toplevel";
      description = ''
        Virtiofs tag used by Tart `--dir ...:tag=<tag>` for NDH top-level share.
      '';
    };

    expectedRunTag = lib.mkOption {
      type = lib.types.str;
      default = "ndh-toplevel";
      description = ''
        Expected Tart run share tag for NDH top-level directory export.
        Keep this aligned with host Tart run wrapper configuration.
      '';
    };

    mountPoint = lib.mkOption {
      type = lib.types.str;
      default = ndhTopLevelMountPointDefault;
      description = ''
        Guest mount point for host-exported NDH repository top-level directory.
      '';
    };
  };

  config = lib.mkIf isTartProvider (
    lib.mkMerge [
      {
        assertions = [
          {
            assertion = bringupMode || (!ndhTopLevelShareEnabled);
            message = ''
              ndh.vm.tart.hostShares.ndhTopLevel.enable is bootstrap-only.
              Set ndh.nixos.generation.mode = "bringup" for bringup images,
              or disable ndh.vm.tart.hostShares.ndhTopLevel for full/runtime images.
            '';
          }
        ];

        systemd.tmpfiles.rules = [
          "d ${tartCiDataRoot} 0755 root root -"
          "d ${ndhRuntimeRoot} 0755 root root -"
          "d ${ndhHostSharesRoot} 0755 root root -"
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

        fileSystems."${config.ndh.vm.tart.hostShares.sopsAge.mountPoint}" = {
          device = config.ndh.vm.tart.hostShares.sopsAge.mountTag;
          fsType = "virtiofs";
          options = [
            "ro"
            "nofail"
          ];
        };
      })

      (lib.mkIf (bringupMode && ndhTopLevelShareEnabled) {
        assertions = [
          {
            assertion =
              config.ndh.vm.tart.hostShares.ndhTopLevel.mountTag
              == config.ndh.vm.tart.hostShares.ndhTopLevel.expectedRunTag;
            message = ''
              ndh.vm.tart.hostShares.ndhTopLevel.mountTag must match ndh.vm.tart.hostShares.ndhTopLevel.expectedRunTag.
              This guards against host/guest Tart NDH top-level share tag drift.
            '';
          }
        ];

        fileSystems."${config.ndh.vm.tart.hostShares.ndhTopLevel.mountPoint}" = {
          device = config.ndh.vm.tart.hostShares.ndhTopLevel.mountTag;
          fsType = "virtiofs";
          options = [
            "rw"
            "nofail"
          ];
        };
      })
    ]
  );
}
