{
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  ...
}:

let
  ndhContext = ndh.context;
  generationMode = ndhContext.generationMode;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  bringupMode = generationMode == "bringup";
  # Production runtime system store path — must be non-empty for bringup mode.
  runtimeSystemPath = ndhContext.runtimeSystemPath or "";
  installRootMountPoint = config.zfsOverlays.bootstrapActivation.installRootMountPoint;
  contributedTargetName = ndhSystemd.contributedTargetName;
  zpoolInitServiceName = ndhSystemd.mkServiceName "zpool-init";

  zfsNixosInstallScriptText =
    builtins.replaceStrings
      [
        "@nixBashTrampoline@"
        "@installRootMountPoint@"
      ]
      [
        nixBashTrampoline
        installRootMountPoint
      ]
      (builtins.readFile ./zfs-nixos-install.sh);

  zfsNixosInstallScript =
    ndh.store.runCommand "ndh-zfs-nixos-install-and-reboot"
      {
        passAsFile = [ "text" ];
        text = zfsNixosInstallScriptText;
      }
      ''
        mkdir -p "$out/bin"
        {
          printf '%s\n' '#!${pkgs.bash}/bin/bash'
          tail -n +2 "$textPath"
        } > "$out/bin/ndh-zfs-nixos-install-and-reboot"
        chmod 0555 "$out/bin/ndh-zfs-nixos-install-and-reboot"
      '';
in
{
  config = lib.mkIf bringupMode {
    assertions = [
      {
        assertion = runtimeSystemPath != "";
        message = ''
          zfs-nixos-install.service requires ndh.context.runtimeSystemPath to be set.
          Pass runtimeSystemPath = selectedRuntime.config.system.build.toplevel when
          calling mkNixosConfig for bringup configurations.
        '';
      }
    ];

    systemd.services.${ndhSystemd.mkUnitName "zfs-nixos-install"} = {
      description = "Install full NixOS onto ZFS datasets during bootstrap and reboot (@codebase)";

      wantedBy = [ contributedTargetName ];
      requires = [ zpoolInitServiceName ];
      wants = [ zpoolInitServiceName ];
      after = [
        "local-fs.target"
        zpoolInitServiceName
      ];

      unitConfig = {
        X-StopOnRemoval = false;
        RequiresMountsFor = [ installRootMountPoint ];
      };

      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "NDH_BOOTSTRAP_INSTALLER_MODE=1"
          "NDH_BOOTSTRAP_STRICT=0"
          "NDH_NIXOS_INSTALL_SYSTEM_PATH=${runtimeSystemPath}"
        ];
        ExecStart = "${zfsNixosInstallScript}/bin/ndh-zfs-nixos-install-and-reboot";
        TimeoutStartSec = "90min";
      };
    };
  };
}
