{
  # WARNING: Never use /net (autofs) as a ZFS dataset mountpoint or overlay source!
  # This will cause ZFS to hang if NFS/autofs is unavailable. Always exclude /net from ZFS overlays.
  config,
  pkgs,
  lib,
  ndh,
  ndhSystemd,
  ...
}:

let
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  cfg = config.zfsOverlays;
  vmProvider = lib.attrByPath [ "ndh" "vm" "provider" ] "lima" config;
  overlayModeEnabled = cfg.overlayMode.enable && vmProvider == "tart";
  providerDataDisks = {
    # Canonical disk layout: boot disk on vda, ZFS data disks on vdb–vde.
    # Identical for both Lima and Tart — both use the same disk images.
    tank1 = "/dev/vdb";
    tank2 = "/dev/vdc";
    tank3 = "/dev/vdd";
    recover = "/dev/vde";
  };
  hostId = config.networking.hostId;
  installRootMountPoint = cfg.bootstrapActivation.installRootMountPoint;
  secondaryEspPartLabelsEnv = lib.concatStringsSep " " cfg.espSync.secondaryEspPartLabels;
  contributedTargetName = ndhSystemd.contributedTargetName;
  zpoolInitUnitName = ndhSystemd.mkUnitName "zpool-init";
  zpoolInitServiceName = ndhSystemd.mkServiceName "zpool-init";
  zfsNixosInstallServiceName = ndhSystemd.mkServiceName "zfs-nixos-install";
  espSyncUnitName = ndhSystemd.mkUnitName "esp-sync";

  joinMountPoints =
    prefix: point:
    if point == "/" then
      prefix
    else if prefix == "/" then
      point
    else
      "${prefix}${point}";

  # --- Recursive flattener for datasets ---
  flattenMountpoints =
    dsSet:
    lib.concatMap (
      name:
      let
        ds = dsSet.${name};
        this =
          if ds ? mountpoint && ds.mountpoint != null then
            [
              {
                mountpoint = ds.mountpoint;
                options = ds.options or { }; # Always an attrset
              }
            ]
          else
            [ ];
        # Disko may use `children` or `datasets` for nested datasets
        children =
          if ds ? children then
            flattenMountpoints ds.children
          else if ds ? datasets then
            flattenMountpoints ds.datasets
          else
            [ ];
      in
      this ++ children
    ) (lib.attrNames dsSet);

  # Build a mapping from mountpoint -> dataset info (including options)
  mountpointList = flattenMountpoints (config.disko.devices.zpool.tank.datasets or { });

  _mountpointMap = lib.listToAttrs (
    map (ds: {
      name = ds.mountpoint;
      value = ds;
    }) mountpointList
  );

  mountpointMap = _mountpointMap;

  mountPoints = lib.attrNames mountpointMap;

  _overlayMountPoints = lib.filter (
    mp:
    let
      ds = mountpointMap.${mp};
    in
    ds.options ? "nixos:mount-overlay" && ds.options."nixos:mount-overlay" == "true"
  ) mountPoints;

  overlayMountPoints = if overlayModeEnabled then _overlayMountPoints else [ ];

  _zfsMountPoints = lib.filter (
    mp:
    let
      ds = mountpointMap.${mp};
    in
    !(ds.options ? "nixos:mount-overlay" && ds.options."nixos:mount-overlay" == "true")
  ) mountPoints;

  # Overlay mode off => mount all datasets directly as ZFS.
  zfsMountPoints = if overlayModeEnabled then _zfsMountPoints else mountPoints;

  fileSystemsMap = lib.foldl' (a: b: a // b) { } config.disko.devices._config.fileSystems.contents;

  zfsLegacyFileSystems = lib.listToAttrs (
    map (mount: {
      name = "${mount}";
      value = fileSystemsMap.${mount} // {
        neededForBoot = true;
        options = [
          "defaults"
          "X-mount.mkdir"
          "zfsutil"
        ];
      };
    }) zfsMountPoints
  );

  zfsOverlayFileSystems = lib.listToAttrs (
    map (mount: {
      name = "/mnt/overlays${mount}";
      value = fileSystemsMap.${mount} // {
        neededForBoot = true;
        options = [
          "defaults"
          "X-mount.mkdir"
          "zfsutil"
        ];
      };
    }) overlayMountPoints
  );

  overlayFileSystems = lib.listToAttrs (
    map (mount: {
      name = mount;
      value = {
        fsType = "overlay";
        device = "overlay";
        neededForBoot = true;
        depends = [ (joinMountPoints "/mnt/overlays" mount) ];
        options = [
          "lowerdir=${mount}"
          "upperdir=${(joinMountPoints "/mnt/overlays" mount) + "/upper"}"
          "workdir=${(joinMountPoints "/mnt/overlays" mount) + "/workdir"}"
          "defaults"
        ];
      };
    }) overlayMountPoints
  );

  fileSystems = zfsLegacyFileSystems // zfsOverlayFileSystems // overlayFileSystems;

  # Extracted so it can be referenced in both ExecCondition and storePaths.
  # NixOS initrd systemd auto-closes ExecStart but not always ExecCondition.
  initrdDevicesCheckScript = ndh.store.writeShellScript "initrd-zpool-init-devices-check" ''
    set -eu

    if ! "${if cfg.bootstrapActivation.autoStart then "true" else "false"}"; then
      echo "[initrd-zpool-init] autoStart=false; skipping"
      exit 1
    fi

    for dev in ${lib.escapeShellArgs cfg.bootstrapActivation.requiredDevices}; do
      if [ ! -b "$dev" ]; then
        echo "[initrd-zpool-init] skip: required device missing: $dev"
        exit 1
      fi
    done

    exit 0
  '';

  zpoolInitText = ''
    export ZFS_DISK_TANK1="${cfg.bootstrapActivation.dataDisks.tank1}"
    export ZFS_DISK_TANK2="${cfg.bootstrapActivation.dataDisks.tank2}"
    export ZFS_DISK_TANK3="${cfg.bootstrapActivation.dataDisks.tank3}"
    export ZFS_DISK_RECOVER="${cfg.bootstrapActivation.dataDisks.recover}"
    ${builtins.replaceStrings [ "@nixBashTrampoline@" ] [ nixBashTrampoline ] (
      builtins.readFile ./zfs.d/zpool-init.sh
    )}
  '';

  zpoolInit =
    ndh.store.runCommand "zpool-init"
      {
        passAsFile = [ "text" ];
        text = zpoolInitText;
      }
      ''
        mkdir -p "$out/bin"
        install -m 0555 "$textPath" "$out/bin/zpool-init"
      '';

  espSyncScriptText = builtins.replaceStrings [ "@nixBashTrampoline@" ] [ nixBashTrampoline ] (
    builtins.readFile ./zfs.d/esp-sync.sh
  );

  espSyncScript =
    ndh.store.runCommand "esp-sync"
      {
        passAsFile = [ "text" ];
        text = espSyncScriptText;
      }
      ''
        install -Dm0555 "$textPath" "$out"
      '';

in
{

  options.zfsOverlays.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable ZFS-backed filesystem definitions and boot integration.";
  };
  options.zfsOverlays.overlayMode.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Enable overlayfs composition for datasets marked with nixos:mount-overlay=true.
      This mode is only active for Tart providers.
    '';
  };
  options.zfsOverlays.sanoid.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Enable sanoid automatic snapshotting policy. Set to false to completely disable automatic ZFS snapshots inside the NixOS VM.";
  };
  options.zfsOverlays.sanoid.datasets = lib.mkOption {
    type = lib.types.attrsOf (
      lib.types.submodule (
        { name, ... }:
        {
          options = {
            recursive = lib.mkOption {
              type = lib.types.bool;
              default = true;
              description = "Snapshot this dataset recursively.";
            };
            yearly = lib.mkOption {
              type = lib.types.int;
              default = 0;
            };
            monthly = lib.mkOption {
              type = lib.types.int;
              default = 0;
            };
            weekly = lib.mkOption {
              type = lib.types.int;
              default = 1;
            };
            daily = lib.mkOption {
              type = lib.types.int;
              default = 2;
            };
            hourly = lib.mkOption {
              type = lib.types.int;
              default = 4;
            };
          };
        }
      )
    );
    default = {
      "tank" = {
        recursive = true;
        yearly = 0;
        monthly = 0;
        weekly = 1;
        daily = 2;
        hourly = 4;
      };
    };
    description = ''
      Attribute set of sanoid dataset policies.

      Keys are full ZFS dataset names (e.g. "tank/nerd/persist"). Values define retention counts to keep; 0 disables that period.

      Example: enable sanoid only for one persistent dataset instead of the whole pool:

        zfsOverlays.sanoid.enable = true;
        zfsOverlays.sanoid.datasets = {
          "tank/nerd/persist" = {
            recursive = false; # no children
            hourly = 4;
            daily = 3;
            weekly = 2;
            monthly = 0;
            yearly = 0;
          };
        };

      To disable snapshots entirely set zfsOverlays.sanoid.enable = false.
    '';
  };
  options.zfsOverlays.bootstrapActivation.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = "Run ZFS bootstrap activation once via a dedicated idempotent systemd unit.";
  };
  options.zfsOverlays.bootstrapActivation.dataDisks = lib.mkOption {
    type = lib.types.submodule {
      options = {
        tank1 = lib.mkOption {
          type = lib.types.str;
          default = providerDataDisks.tank1;
          description = "Block device path for primary tank member disk.";
        };
        tank2 = lib.mkOption {
          type = lib.types.str;
          default = providerDataDisks.tank2;
          description = "Block device path for secondary tank member disk.";
        };
        tank3 = lib.mkOption {
          type = lib.types.str;
          default = providerDataDisks.tank3;
          description = "Block device path for tertiary tank member disk.";
        };
        recover = lib.mkOption {
          type = lib.types.str;
          default = providerDataDisks.recover;
          description = "Block device path for recover pool disk.";
        };
      };
    };
    default = { };
    description = ''
      Canonical block-device mapping used by disko bootstrap provisioning.
      Defaults are provider-specific and can be overridden per host/profile.
    '';
  };
  options.zfsOverlays.bootstrapActivation.autoStart = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Auto-start ZFS bootstrap activation by wiring the zpool-init service to systemd boot targets.
      Set to false for temporary inspect/debug boots where zpool-init must not run automatically.
    '';
  };
  options.zfsOverlays.bootstrapActivation.requiredDevices = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      providerDataDisks.tank1
      providerDataDisks.tank2
      providerDataDisks.tank3
      providerDataDisks.recover
    ];
    description = ''
      Block devices that must be present before running bootstrap datastore provisioning.
      This keeps first boot safe for Tart/Lima when extra data disks are not yet attached.
    '';
  };
  options.zfsOverlays.bootstrapActivation.installRootMountPoint = lib.mkOption {
    type = lib.types.str;
    default = "/mnt/zfs-root";
    description = ''
      Canonical target root mountpoint used by disko and bootstrap NixOS install flow.
    '';
  };
  options.zfsOverlays.espSync.secondaryEspPartLabels = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "esp-tank1"
      "esp-tank2"
      "esp-tank3"
      "esp-recover"
    ];
    description = ''
      Canonical ordered list of secondary ESP partition labels mirrored from primary ESP.
      These labels are exported to esp-sync via SECONDARY_ESP_PART_LABELS.
    '';
  };
  config = {

    # Keep disko root mountpoint aligned with the canonical bootstrap target.
    # This makes flake-based disko invocations deterministic and consistent
    # with zpool-init/zfs-install scripts.
    disko.rootMountPoint = lib.mkDefault installRootMountPoint;

    networking.hostId = lib.mkDefault hostId;

    boot = {
      supportedFilesystems = lib.mkAfter [ "zfs" ];
      initrd = {
        supportedFilesystems = lib.mkAfter (lib.optional config.zfsOverlays.enable "zfs");
      };
      zfs = (
        lib.mkIf config.zfsOverlays.enable {
          forceImportRoot = false;
          devNodes = lib.mkForce "/dev/disk/by-partlabel";
          extraPools = [
            "tank"
            "recover"
          ];
        }
      );

      loader.systemd-boot.extraInstallCommands = lib.mkIf config.boot.loader.systemd-boot.enable (
        lib.mkAfter ''
          export SECONDARY_ESP_PART_LABELS=${lib.escapeShellArg secondaryEspPartLabelsEnv}
          ${espSyncScript}
        ''
      );
    };

    # ZFS runtime services
    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };

    services.sanoid = lib.mkIf config.zfsOverlays.sanoid.enable {
      enable = true;
      datasets = config.zfsOverlays.sanoid.datasets;
    };

    fileSystems = (
      lib.mkIf config.zfsOverlays.enable (
        lib.mkMerge [ (lib.mapAttrs (_: fs: lib.mkForce fs) fileSystems) ]
      )
    );

    # Runtime tooling
    environment.systemPackages = [
      pkgs.zfs
      zpoolInit
    ];

    # Explicitly include ExecCondition script in the initrd store.
    # NixOS auto-closes ExecStart paths but not always ExecCondition.
    boot.initrd.systemd.storePaths = lib.mkIf (
      config.zfsOverlays.bootstrapActivation.enable && config.zfsOverlays.enable && (!overlayModeEnabled)
    ) [ initrdDevicesCheckScript ];

    boot.initrd.systemd.services.${zpoolInitUnitName} =
      lib.mkIf
        (
          config.zfsOverlays.bootstrapActivation.enable && config.zfsOverlays.enable && (!overlayModeEnabled)
        )
        {
          description = "Stage1 idempotent ZFS disko provisioning (@codebase)";
          wantedBy = [ "initrd.target" ];
          after = [
            "systemd-udevd.service"
            "systemd-udev-settle.service"
          ];
          before = [
            "initrd-root-fs.target"
            "sysroot.mount"
          ];
          path = with pkgs; [
            bash
            coreutils
            util-linux
            gawk
            systemd
            zfs
            disko
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardOutput = "journal+console";
            StandardError = "journal+console";
            ExecCondition = initrdDevicesCheckScript;
            ExecStart = ndh.store.writeShellScript "initrd-zpool-init" ''
              set -euxo pipefail

              # Some bootstrap images may accidentally contain /homeless-shelter,
              # which makes nix/disko refuse impurity-prone builds.
              if [ -d /homeless-shelter ]; then
                rm -rf /homeless-shelter
              fi

              export NDH_BOOTSTRAP_INSTALLER_MODE=1
              export NDH_BOOTSTRAP_STRICT=0
              exec ${zpoolInit}/bin/zpool-init
            '';
            TimeoutStartSec = "30min";
          };
        };

    systemd = {
      services.${zpoolInitUnitName} = lib.mkMerge [
        (lib.mkIf (config.zfsOverlays.bootstrapActivation.enable && overlayModeEnabled) {
          description = "Idempotent one-shot ZFS disk/datastore provisioning (@codebase)";
          wantedBy = [ "zfs-import.target" ];
          before = [
            "zfs-import.target"
            "zfs-import-cache.service"
            "zfs-import-scan.service"
            "zfs-mount.service"
          ];

          path = with pkgs; [
            bash
            coreutils
            util-linux
            gawk
            systemd
            zfs
            disko
          ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            ExecCondition = ndh.store.writeShellScript "zpool-init-devices-check" ''
              set -eu

              if ! "${if config.zfsOverlays.bootstrapActivation.autoStart then "true" else "false"}"; then
                echo "[zpool-init] autoStart is false; skipping device check and zpool-init execution"
                exit 1
              fi

              for dev in ${lib.escapeShellArgs config.zfsOverlays.bootstrapActivation.requiredDevices}; do
                if [ ! -b "$dev" ]; then
                  echo "[zpool-init] skip: required device missing: $dev"
                  exit 1
                fi
              done

              exit 0
            '';
            ExecStart = ndh.store.writeShellScript "zpool-init" ''
              set -euxo pipefail

              # Some bootstrap images may accidentally contain /homeless-shelter,
              # which makes nix/disko refuse impurity-prone builds.
              if [ -d /homeless-shelter ]; then
                rm -rf /homeless-shelter
              fi

              # This early-boot service runs with explicit systemd path inputs;
              # skip NDH bootstrap profile strict checks to avoid a noisy pre-flight
              # failure phase before the actual zpool-init execution.
              export NDH_BOOTSTRAP_INSTALLER_MODE=1
              export NDH_BOOTSTRAP_STRICT=0

              exec ${zpoolInit}/bin/zpool-init
            '';
            TimeoutStartSec = "30min";
          };

          unitConfig = {
            X-StopOnRemoval = false;
          };
        })

        # Non-overlay mode (e.g., Lima bootstrap ext4 -> prepare ZFS for next boot)
        # runs in stage-2 after local filesystems are available.
        (lib.mkIf (config.zfsOverlays.bootstrapActivation.enable && (!overlayModeEnabled)) {
          description = "Stage2 idempotent ZFS disk/datastore provisioning (@codebase)";
          wantedBy = [ contributedTargetName ];
          after = [
            "local-fs.target"
            "systemd-udevd.service"
            "systemd-udev-settle.service"
          ];
          before = [ zfsNixosInstallServiceName ];

          path = with pkgs; [
            bash
            coreutils
            util-linux
            gawk
            systemd
            zfs
            disko
          ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardOutput = "journal+console";
            StandardError = "journal+console";
            ExecCondition = ndh.store.writeShellScript "zpool-init-devices-check" ''
              set -eu

              if ! "${if config.zfsOverlays.bootstrapActivation.autoStart then "true" else "false"}"; then
                echo "[zpool-init] autoStart is false; skipping device check and zpool-init execution"
                exit 1
              fi

              for dev in ${lib.escapeShellArgs config.zfsOverlays.bootstrapActivation.requiredDevices}; do
                if [ ! -b "$dev" ]; then
                  echo "[zpool-init] skip: required device missing: $dev"
                  exit 1
                fi
              done

              exit 0
            '';
            ExecStart = ndh.store.writeShellScript "zpool-init" ''
              set -euxo pipefail

              # Some bootstrap images may accidentally contain /homeless-shelter,
              # which makes nix/disko refuse impurity-prone builds.
              if [ -d /homeless-shelter ]; then
                rm -rf /homeless-shelter
              fi

              export NDH_BOOTSTRAP_INSTALLER_MODE=1
              export NDH_BOOTSTRAP_STRICT=0
              exec ${zpoolInit}/bin/zpool-init
            '';
            TimeoutStartSec = "30min";
          };

          unitConfig = {
            X-StopOnRemoval = false;
          };
        })
      ];

      services.${espSyncUnitName} = {
        description = "Mirror primary ESP to additional ESP partitions (@codebase)";
        wantedBy = [ "multi-user.target" ];
        after = [
          "local-fs.target"
          "boot.mount"
        ];
        wants = [ "boot.mount" ];
        path = with pkgs; [
          bash
          coreutils
          util-linux
          dosfstools
        ];
        serviceConfig = {
          Type = "oneshot";
          ExecStart = ndh.store.writeShellScript "esp-sync-service" ''
            set -eu
            export SECONDARY_ESP_PART_LABELS=${lib.escapeShellArg secondaryEspPartLabelsEnv}
            exec ${espSyncScript}
          '';
        };
      };
      tmpfiles.rules = [
        # ensure utmp + wtmp exist on the real root under /run
        "f /run/utmp 0664 root utmp -"
        "f /run/wtmp 0664 root utmp -"
      ];

      shutdownRamfs.contents."/etc/systemd/system-shutdown/zpool".source = (
        lib.mkForce (
          pkgs.replaceVars ./zfs.d/zpool-sync-export-shutdown.sh {
            zpool = "${pkgs.zfs}/bin/zpool";
          }
        )
      );

      shutdownRamfs.storePaths = [ "${pkgs.zfs}/bin/zpool" ];
    };

  };
}
