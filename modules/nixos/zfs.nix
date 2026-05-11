{
  # WARNING: Never use /net (autofs) as a ZFS dataset mountpoint or overlay source!
  # This will cause ZFS to hang if NFS/autofs is unavailable. Always exclude /net from ZFS overlays.
  config,
  pkgs,
  lib,
  ndh ? null,
  ndhSystemd ? null,
  ...
}:

let
  # Safe defaults for minimal systems where ndh/ndhSystemd are not available
  ndhContext = if ndh != null then ndh.context else { nixBashTrampoline = "${pkgs.bash}/bin/bash"; generationMode = "full"; };
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  generationMode = ndhContext.generationMode or "full";
  bringupMode = generationMode == "bringup";
  # Fallback to pkgs for store operations when ndh.store is not available
  ndhStore = if ndh != null then ndh.store else pkgs;
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
  primaryEspPartLabelEnv = cfg.espSync.primaryEspPartLabel;
  secondaryEspPartLabelsEnv = lib.concatStringsSep " " cfg.espSync.secondaryEspPartLabels;

  # Fallback unit naming when ndhSystemd is not available (minimal systems)
  mkUnitNameFallback = name: "${name}";
  mkServiceNameFallback = name: "${name}.service";
  contributedTargetName = if ndhSystemd != null then ndhSystemd.contributedTargetName else "multi-user.target";
  zpoolInitUnitName = if ndhSystemd != null then ndhSystemd.mkUnitName "zpool-init" else mkUnitNameFallback "zpool-init";
  zpoolInitServiceName = if ndhSystemd != null then ndhSystemd.mkServiceName "zpool-init" else mkServiceNameFallback "zpool-init";
  bootReconcileUnitName = if ndhSystemd != null then ndhSystemd.mkUnitName "boot-entry-reconcile" else mkUnitNameFallback "boot-entry-reconcile";
  bootReconcileServiceName = if ndhSystemd != null then ndhSystemd.mkServiceName "boot-entry-reconcile" else mkServiceNameFallback "boot-entry-reconcile";
  zfsNixosInstallServiceName = if ndhSystemd != null then ndhSystemd.mkServiceName "zfs-nixos-install" else mkServiceNameFallback "zfs-nixos-install";
  espSyncUnitName = if ndhSystemd != null then ndhSystemd.mkUnitName "esp-sync" else mkUnitNameFallback "esp-sync";

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

  # Extracted so it can be referenced in both ExecCondition/ExecStart and storePaths.
  # NixOS initrd systemd does NOT auto-close ExecStart or ExecCondition store paths —
  # both must be explicitly listed in boot.initrd.systemd.storePaths.
  initrdDevicesCheckScript = ndhStore.writeShellScript "initrd-zpool-init-devices-check" ''
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
    export SGDISK_BIN="${pkgs.gptfdisk}/bin/sgdisk"
    export BLOCKDEV_BIN="${pkgs.util-linux}/bin/blockdev"
    ${builtins.replaceStrings [ "@nixBashTrampoline@" ] [ nixBashTrampoline ] (
      builtins.readFile ./zfs.d/zpool-init.sh
    )}
  '';

  zpoolInit =
    ndhStore.runCommand "zpool-init"
      {
        passAsFile = [ "text" ];
        text = zpoolInitText;
      }
      ''
        mkdir -p "$out/bin"
        install -m 0555 "$textPath" "$out/bin/zpool-init"
      '';

  # Extracted so it can be referenced in both ExecStart and storePaths.
  initrdZpoolInitScript = ndhStore.writeShellScript "initrd-zpool-init" ''
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

  # Extracted so it can be referenced in both ExecStart and storePaths.
  initrdBootEntryReconcileScript = ndhStore.writeShellScript "initrd-boot-entry-reconcile" ''
    set -euo pipefail

    sysroot=/sysroot

    # ── Detect the ESP via the EFI variable set by systemd-boot ──────────────
    # LoaderDevicePartUUID contains the UUID of the partition the bootloader
    # loaded from. This is authoritative — don't assume /dev/vda1 or /boot.
    LOADER_EFI_VAR=/sys/firmware/efi/efivars/LoaderDevicePartUUID-4a67b082-0a4c-41cf-b6c7-440b29bb8c4f
    esp_dev=""
    if [[ -r "$LOADER_EFI_VAR" ]]; then
      # EFI variable: 4-byte attribute header + UTF-16LE UUID value.
      # Skip the header with dd, then keep only UUID-valid chars (the null
      # bytes from UTF-16LE encoding and the header are silently dropped).
      esp_uuid="$(dd if="$LOADER_EFI_VAR" bs=1 skip=4 2>/dev/null \
        | tr -cd 'a-fA-F0-9-' | tr '[:upper:]' '[:lower:]')" || esp_uuid=""
      if [[ -n "$esp_uuid" ]]; then
        esp_dev="$(blkid -t "PARTUUID=$esp_uuid" -o device 2>/dev/null || true)"
        echo "[boot-reconcile] ESP PARTUUID=$esp_uuid → $esp_dev" >&2
      fi
    fi

    if [[ -z "$esp_dev" ]]; then
      echo "[boot-reconcile] WARN: cannot detect ESP via EFI var — falling back to sysroot/boot" >&2
      boot_dir="$sysroot/boot"
    else
      boot_dir="$(mktemp -d /run/boot-reconcile-esp.XXXXXX)"
      mount -t vfat -o ro,noatime "$esp_dev" "$boot_dir" 2>/dev/null || {
        echo "[boot-reconcile] WARN: failed to mount $esp_dev — falling back to sysroot/boot" >&2
        rmdir "$boot_dir" 2>/dev/null || true
        boot_dir="$sysroot/boot"
        esp_dev=""
      }
    fi

    cleanup() {
      if [[ -n "$esp_dev" ]] && mountpoint -q "$boot_dir" 2>/dev/null; then
        # Remount rw only if we need to write
        :
      fi
    }
    trap cleanup EXIT

    # ── Parse init= from kernel cmdline ──────────────────────────────────────
    cmdline_init=""
    for o in $(cat /proc/cmdline); do
      case "$o" in
        init=*) cmdline_init="''${o#init=}" ;;
      esac
    done

    if [[ -z "$cmdline_init" ]]; then
      echo "[boot-reconcile] no init= in cmdline, skipping" >&2
      exit 0
    fi

    cmdline_system="$(dirname "$cmdline_init")"

    if [[ -d "$sysroot$cmdline_system" ]]; then
      echo "[boot-reconcile] boot entry matches sysroot — OK" >&2
      exit 0
    fi

    echo "[boot-reconcile] WARN: boot entry points to missing system: $cmdline_system" >&2

    # ── Find the actual system in the ZFS sysroot store ──────────────────────
    actual_system="$(find "$sysroot/nix/store" -maxdepth 1 -name '*-nixos-system-*' -type d 2>/dev/null | sort | tail -1)"

    if [[ -z "$actual_system" ]]; then
      echo "[boot-reconcile] WARN: no nixos-system in $sysroot/nix/store — cannot reconcile" >&2
      exit 0
    fi

    actual_system_rel="''${actual_system#"$sysroot"}"
    echo "[boot-reconcile] reconciling boot entries to: $actual_system_rel" >&2

    if [[ ! -d "$boot_dir/loader/entries" ]]; then
      echo "[boot-reconcile] WARN: no systemd-boot entries at $boot_dir — skipping" >&2
      exit 0
    fi

    # Remount rw for writing if we mounted the ESP ourselves
    if [[ -n "$esp_dev" ]] && mountpoint -q "$boot_dir" 2>/dev/null; then
      mount -o remount,rw "$boot_dir"
    fi

    old_init="$cmdline_system/init"
    new_init="$actual_system_rel/init"
    updated=0

    for entry in "$boot_dir/loader/entries/"*.conf; do
      [[ -f "$entry" ]] || continue
      if grep -q "$old_init" "$entry"; then
        sed -i "s|$old_init|$new_init|g" "$entry"
        echo "[boot-reconcile] updated: $(basename "$entry")" >&2
        updated=1
      fi
    done

    if [[ "$updated" -eq 0 ]]; then
      echo "[boot-reconcile] WARN: no entries contained old init path" >&2
    fi

    # Unmount the ESP if we mounted it ourselves
    if [[ -n "$esp_dev" ]] && mountpoint -q "$boot_dir" 2>/dev/null; then
      umount "$boot_dir"
      rmdir "$boot_dir" 2>/dev/null || true
    fi
  '';

  espSyncScriptText = builtins.replaceStrings [ "@nixBashTrampoline@" ] [ nixBashTrampoline ] (
    builtins.readFile ./zfs.d/esp-sync.sh
  );

  espSyncScript =
    ndhStore.runCommand "esp-sync"
      {
        passAsFile = [ "text" ];
        text = espSyncScriptText;
      }
      ''
        install -Dm0555 "$textPath" "$out"
      '';

  # Stage-2 packages shared by overlay-mode and non-overlay-mode bootstrap services.
  stage2ZpoolInitDevicesCheckPackage = ndhStore.writeShellScriptBin "zpool-init-devices-check" ''
    set -eu

    if ! "${if cfg.bootstrapActivation.autoStart then "true" else "false"}"; then
      echo "[zpool-init] autoStart is false; skipping device check and zpool-init execution"
      exit 1
    fi

    for dev in ${lib.escapeShellArgs cfg.bootstrapActivation.requiredDevices}; do
      if [ ! -b "$dev" ]; then
        echo "[zpool-init] skip: required device missing: $dev"
        exit 1
      fi
    done

    exit 0
  '';

  stage2ZpoolInitPackage = ndhStore.writeShellScriptBin "zpool-init" ''
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

  espSyncServicePackage = ndhStore.writeShellScriptBin "esp-sync-service" ''
    set -eu
    export PRIMARY_ESP_PART_LABEL=${lib.escapeShellArg primaryEspPartLabelEnv}
    export SECONDARY_ESP_PART_LABELS=${lib.escapeShellArg secondaryEspPartLabelsEnv}
    exec ${espSyncScript}
  '';

  zpoolSyncExportShutdownScript = ndhStore.installScript {
    name = "zpool-sync-export-shutdown";
    source = pkgs.replaceVars ./zfs.d/zpool-sync-export-shutdown.sh {
      zpool = "${pkgs.zfs}/bin/zpool";
    };
    mode = "0755";
  };

in
let
  partLayout = import ./zfs-partition-layout.nix;
in
{

  options.zfsOverlays.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable ZFS-backed filesystem definitions and boot integration.";
  };
  options.zfsOverlays.repart.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = ''
      Enable systemd-repart in the initrd to automatically grow ZFS data-disk
      partitions when Lima/Tart resizes disk images.  Set to true on minimal
      bringup systems; the full runtime system uses zpool-init instead.
    '';
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
  options.zfsOverlays.espSync.primaryEspPartLabel = lib.mkOption {
    type = lib.types.str;
    default = "esp-boot";
    description = ''
      Partition label of the primary ESP — the one mounted at /boot where
      systemd-boot installs itself. Content is mirrored FROM this partition
      to all secondaryEspPartLabels.
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

  # Single source of truth for the disk partition layout shared between
  # zfs-disko-config.nix (build-time) and systemd-repart (runtime grow).
  options.zfsOverlays.diskLayout.espSizeMiB = lib.mkOption {
    type = lib.types.int;
    default = partLayout.espSizeMiB;
    description = ''
      Size of the ESP partition in MiB. Must match the espSizeMiB parameter
      passed to zfs-disko-config.nix at bringup image build time. Referenced by
      systemd-repart to pin the ESP boundary when growing ZFS partitions.
    '';
  };
  options.zfsOverlays.diskLayout.zfsPartitionTypeGuid = lib.mkOption {
    type = lib.types.str;
    default = partLayout.zfsPartitionTypeGuid;
    description = ''
      GPT partition type GUID for ZFS partitions (Solaris/ZFS canonical GUID,
      equivalent to gdisk type code BF01). Must match what disko writes at bringup
      build time. Referenced by systemd-repart to identify ZFS partitions to grow.
    '';
  };

  config = {

    # Keep disko root mountpoint aligned with the canonical bootstrap target.
    # This makes flake-based disko invocations deterministic and consistent
    # with zpool-init/zfs-install scripts.
    disko.rootMountPoint = lib.mkDefault installRootMountPoint;

    networking.hostId = lib.mkDefault hostId;

    # Grow ZFS data-disk partitions in the initrd when disk images have been
    # enlarged on the host (e.g. Lima diskSize increase). systemd-repart runs
    # before any ZFS import. Combined with autoexpand=on on the pools the
    # online expansion is fully automatic — no manual `zpool online -e` needed.
    boot.initrd.systemd.repart.enable = lib.mkIf config.zfsOverlays.repart.enable true;
    systemd.repart.partitions = lib.mkIf config.zfsOverlays.repart.enable {
      # Pin the ESP at exactly its build-time size — never grow or shrink it.
      "10-esp" = {
        Type = "esp";
        SizeMinBytes = "${toString config.zfsOverlays.diskLayout.espSizeMiB}M";
        SizeMaxBytes = "${toString config.zfsOverlays.diskLayout.espSizeMiB}M";
      };
      # Grow the ZFS partition to the end of the disk.
      # GrowFileSystem=off: ZFS handles its own online expansion via autoexpand=on.
      "20-zfs" = {
        Type = config.zfsOverlays.diskLayout.zfsPartitionTypeGuid;
        GrowFileSystem = "off";
      };
    };

    boot = {
      supportedFilesystems = lib.mkAfter [ "zfs" ];
      initrd = {
        supportedFilesystems = lib.mkAfter (lib.optional config.zfsOverlays.enable "zfs");
      };
      zfs = (
        lib.mkIf config.zfsOverlays.enable {
          forceImportRoot = true;
          devNodes = lib.mkForce "/dev";
          extraPools = [
            "tank"
            "recover"
          ];
        }
      );

      loader.systemd-boot.extraInstallCommands = lib.mkIf (config.boot.loader.systemd-boot.enable && !bringupMode) (
        lib.mkAfter ''
          export PRIMARY_ESP_PART_LABEL=${lib.escapeShellArg primaryEspPartLabelEnv}
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

    # Explicitly include both ExecCondition and ExecStart scripts in the initrd store.
    # NixOS does NOT auto-close either — both must be listed explicitly.
    # zpoolInit and its runtime deps (gptfdisk, util-linux) are also required because
    # initrdZpoolInitScript does `exec ${zpoolInit}/bin/zpool-init` which embeds
    # absolute store paths that must exist in the initrd /nix/store.
    boot.initrd.systemd.storePaths = lib.mkMerge [
      (lib.mkIf
        (
          config.zfsOverlays.bootstrapActivation.enable && config.zfsOverlays.enable && (!overlayModeEnabled)
        )
        [
          initrdDevicesCheckScript
          initrdZpoolInitScript
          zpoolInit
          pkgs.gptfdisk
          pkgs.util-linux
          pkgs.yq-go
        ]
      )
      (lib.mkIf (config.zfsOverlays.enable && (!overlayModeEnabled)) [ initrdBootEntryReconcileScript ])
    ];

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
            gptfdisk
            systemd
            zfs
            yq-go
            disko
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardOutput = "journal+console";
            StandardError = "journal+console";
            ExecCondition = initrdDevicesCheckScript;
            ExecStart = initrdZpoolInitScript;
            TimeoutStartSec = "30min";
          };
        };

    # Boot-entry reconcile service: runs in the initrd after /sysroot/nix/store
    # is mounted, before initrd-find-nixos-closure. When the ZFS tank disks are
    # provisioned from a newer bringup image than what wrote the ESP boot entries,
    # the init= path in the boot entry may reference a system closure that no
    # longer exists in the ZFS store. This service detects the mismatch and
    # rewrites the systemd-boot .conf entries to point at the system closure
    # that is actually present.
    boot.initrd.systemd.services.${bootReconcileUnitName} =
      lib.mkIf (config.zfsOverlays.enable && (!overlayModeEnabled))
        {
          description = "Reconcile EFI boot entry with ZFS store system closure";
          unitConfig = {
            # Only need the ZFS store mounted to find the actual system closure.
            # The ESP is detected via LoaderDevicePartUUID EFI variable and mounted
            # by the script itself — /sysroot/boot may not exist on all layouts.
            RequiresMountsFor = [ "/sysroot/nix/store" ];
            DefaultDependencies = false;
          };
          after = [
            "sysroot.mount"
            "systemd-udevd.service"
            "systemd-udev-settle.service"
          ];
          before = [
            "initrd-find-nixos-closure.service"
            "initrd.target"
          ];
          wantedBy = [ "initrd.target" ];
          path = with pkgs; [
            bash
            coreutils
            gnugrep
            gnused
            findutils
            util-linux
          ];
          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardOutput = "journal+console";
            StandardError = "journal+console";
            ExecStart = initrdBootEntryReconcileScript;
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
            ExecCondition = "${stage2ZpoolInitDevicesCheckPackage}/bin/zpool-init-devices-check";
            ExecStart = "${stage2ZpoolInitPackage}/bin/zpool-init";
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
            ExecCondition = "${stage2ZpoolInitDevicesCheckPackage}/bin/zpool-init-devices-check";
            ExecStart = "${stage2ZpoolInitPackage}/bin/zpool-init";
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
          ExecStart = "${espSyncServicePackage}/bin/esp-sync-service";
        };
      };

      tmpfiles.rules = [
        # ensure utmp + wtmp exist on the real root under /run
        "f /run/utmp 0664 root utmp -"
        "f /run/wtmp 0664 root utmp -"
      ];

      shutdownRamfs.contents."/etc/systemd/system-shutdown/zpool".source = (
        lib.mkForce zpoolSyncExportShutdownScript
      );

      shutdownRamfs.storePaths = [ "${pkgs.zfs}/bin/zpool" ];
    };

  };
}
