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
  hostProfile = ndhContext.hostProfile;
  mainName =
    if (hostProfile ? hostAlias && hostProfile.hostAlias != null && hostProfile.hostAlias != "") then
      hostProfile.hostAlias
    else
      hostProfile.hostName;
  nixosConfigName = "${mainName}-nixos";
  isLimaProvider = config.ndh.vm.provider == "lima";
  isTartProvider = config.ndh.vm.provider == "tart";
  ndhTopLevelMountPoint =
    if isLimaProvider then
      "/run/ndh/host-shares/ndh-toplevel"
    else
      "/srv/host/nixos.d";
  installRootMountPoint = config.zfsOverlays.bootstrapActivation.installRootMountPoint;
  contributedTargetName = ndhSystemd.contributedTargetName;
  zpoolInitServiceName = ndhSystemd.mkServiceName "zpool-init";
  limaCloudInitServiceName = ndhSystemd.mkServiceName "lima-cloud-init";
  limaNixosConfigServiceName = ndhSystemd.mkServiceName "lima-nixos-config";

  zfsNixosInstallScriptText =
    builtins.replaceStrings
      [
        "@nixBashTrampoline@"
        "@nixosConfigName@"
        "@ndhTopLevelMountPoint@"
        "@installRootMountPoint@"
      ]
      [
        nixBashTrampoline
        nixosConfigName
        ndhTopLevelMountPoint
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
    systemd.services.${ndhSystemd.mkUnitName "zfs-nixos-install"} = {
      description = "Install full NixOS onto ZFS datasets during bootstrap and reboot (@codebase)";

      wantedBy = [ contributedTargetName ];
      requires = [ zpoolInitServiceName ];
      wants = [
        zpoolInitServiceName
      ]
      ++ lib.optionals isLimaProvider [
        limaCloudInitServiceName
        limaNixosConfigServiceName
      ];
      after = [
        "local-fs.target"
        zpoolInitServiceName
      ]
      ++ lib.optionals isLimaProvider [
        limaCloudInitServiceName
        limaNixosConfigServiceName
      ];

      unitConfig = lib.mkMerge [
        {
          X-StopOnRemoval = false;
          RequiresMountsFor = [
            installRootMountPoint
          ]
          ++ lib.optionals (isTartProvider || isLimaProvider) [ ndhTopLevelMountPoint ];
        }
        (lib.mkIf (isTartProvider || isLimaProvider) {
          ConditionPathIsMountPoint = ndhTopLevelMountPoint;
          ConditionPathExists = "${ndhTopLevelMountPoint}/flake.nix";
        })
      ];

      serviceConfig = {
        Type = "oneshot";
        Environment = [
          "NDH_BOOTSTRAP_INSTALLER_MODE=1"
          "NDH_BOOTSTRAP_STRICT=0"
        ];
        ExecStart = "${zfsNixosInstallScript}/bin/ndh-zfs-nixos-install-and-reboot";
        TimeoutStartSec = "90min";
      };
    };
  };
}
