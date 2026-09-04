{
  # WARNING: Never use /net (autofs) as a ZFS dataset mountpoint or overlay source!
  # This will cause ZFS to hang if NFS/autofs is unavailable. Always exclude /net from ZFS overlays.
  config,
  pkgs,
  lib,
  ndh ? null,
  ndhSystemd ? null,
  utils,
  ...
}:

let
  # Safe defaults for minimal systems where ndh/ndhSystemd are not available
  ndhContext =
    if ndh != null then
      ndh.context
    else
      {
        nixBashTrampoline = "${pkgs.bash}/bin/bash";
        generationMode = "full";
      };
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";
  # The trampoline is a file inside a store-path directory that also carries
  # logger.sh; `source nix-bash-trampoline.sh` pulls logger.sh from the same
  # dirname.  Derive the directory from the file path so the initrd can keep
  # the whole directory alive via boot.initrd.systemd.storePaths.
  nixBashTrampolineDir = builtins.dirOf nixBashTrampoline;
  generationMode = ndhContext.generationMode or "full";
  bringupMode = generationMode == "bringup";
  # Fallback to pkgs for store operations when ndh.store is not available
  ndhStore = if ndh != null then ndh.store else pkgs;
  cfg = config.zfsOverlays;
  vmProvider = lib.attrByPath [ "ndh" "vm" "provider" ] "tart" config;
  overlayModeEnabled = cfg.overlayMode.enable && vmProvider == "tart";
  providerDataDisks = {
    # Canonical disk layout: boot disk on vda, ZFS data disks on vdb–vde.
    # Uses the same disk images as the bringup build.
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
  contributedTargetName =
    if ndhSystemd != null then ndhSystemd.contributedTargetName else "multi-user.target";
  zpoolInitUnitName =
    if ndhSystemd != null then ndhSystemd.mkUnitName "zpool-init" else mkUnitNameFallback "zpool-init";
  zpoolInitServiceName =
    if ndhSystemd != null then
      ndhSystemd.mkServiceName "zpool-init"
    else
      mkServiceNameFallback "zpool-init";
  bootReconcileUnitName =
    if ndhSystemd != null then
      ndhSystemd.mkUnitName "boot-entry-reconcile"
    else
      mkUnitNameFallback "boot-entry-reconcile";
  bootReconcileServiceName =
    if ndhSystemd != null then
      ndhSystemd.mkServiceName "boot-entry-reconcile"
    else
      mkServiceNameFallback "boot-entry-reconcile";
  zfsNixosInstallServiceName =
    if ndhSystemd != null then
      ndhSystemd.mkServiceName "zfs-nixos-install"
    else
      mkServiceNameFallback "zfs-nixos-install";
  espSyncUnitName =
    if ndhSystemd != null then ndhSystemd.mkUnitName "esp-sync" else mkUnitNameFallback "esp-sync";

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

  # Non-ZFS filesystems disko declared — today that's the ESP mounted
  # at /boot (vfat on /dev/vda1), tomorrow potentially any other
  # non-ZFS mount the disko schema adds.  We can't rely on disko's own
  # `config.fileSystems` emission because zfs-disko-config.nix sets
  # `enableConfig = false` to keep the ZFS reconstruction below in
  # charge; so walk `fileSystemsMap` (disko's raw mountpoint →
  # descriptor map) and pull in every entry our ZFS/overlay accounting
  # hasn't already claimed.
  nonZfsFileSystems =
    let
      zfsClaimed = zfsMountPoints ++ overlayMountPoints;
    in
    lib.filterAttrs (mp: _: !(lib.elem mp zfsClaimed)) fileSystemsMap;

  fileSystems =
    zfsLegacyFileSystems // zfsOverlayFileSystems // overlayFileSystems // nonZfsFileSystems;

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

  # Derive runtime pool + dataset-mountpoint maps from disko so zpool-init
  # stays in sync when a new pool or dataset is added to zfs-disko-config.nix.
  # Pool list:  `.disko.devices.zpool` attribute names.
  # Mount map:  for each pool, walk `.datasets.<name>` recursively; every
  #             dataset that declares `mountpoint` as a concrete path yields
  #             one "<pool>/<relative> <mountpoint>" line.  Legacy / none /
  #             null mountpoints are skipped — those are owned by callers
  #             (e.g. rke2 containerd datasets).
  diskoPoolList = lib.attrNames (config.disko.devices.zpool or { });

  diskoPoolDatasetMountpoints =
    poolName:
    let
      poolCfg = config.disko.devices.zpool.${poolName};
      walk =
        prefix: dsSet:
        lib.concatMap (
          name:
          let
            ds = dsSet.${name};
            # Disko uses `name/child` as the attribute name for nested datasets,
            # so prefix is always `<pool>` and we concat directly.
            fullName = "${prefix}/${name}";
            this =
              if ds ? mountpoint && ds.mountpoint != null && lib.hasPrefix "/" (toString ds.mountpoint) then
                [
                  {
                    dataset = fullName;
                    mountpoint = ds.mountpoint;
                  }
                ]
              else
                [ ];
            children =
              if ds ? datasets then
                walk fullName ds.datasets
              else if ds ? children then
                walk fullName ds.children
              else
                [ ];
          in
          this ++ children
        ) (lib.attrNames dsSet);
    in
    walk poolName (poolCfg.datasets or { });

  diskoAllMountpoints = lib.concatMap diskoPoolDatasetMountpoints diskoPoolList;

  # Single heredoc body for zpool-init.sh — one "dataset mountpoint" line per
  # entry, matching the original hard-coded table's shape.
  zpoolInitMountpointsTable = lib.concatMapStringsSep "\n" (
    e: "${e.dataset} ${toString e.mountpoint}"
  ) diskoAllMountpoints;

  # Full dataset inventory (name + declared ZFS properties) for zpool-init's
  # create-if-absent pass.  Unlike diskoAllMountpoints (concrete mountpoints only,
  # feeding the reconcile), this yields EVERY disko-declared dataset — so a subtree
  # added after the pool was first provisioned (e.g. rke2lab's dataplan landing on a
  # running host) gets created on the next activation instead of silently missing
  # (disko only creates at install time).  Each entry carries its real ZFS options;
  # nixos:* pseudo-properties (overlay markers consumed at eval by the fileSystems
  # wiring, not real ZFS props) are filtered out, and a concrete top-level `mountpoint`
  # is folded in as a property so a fresh create is faithful.
  diskoPoolDatasetInventory =
    poolName:
    let
      poolCfg = config.disko.devices.zpool.${poolName};
      walk =
        prefix: dsSet:
        lib.concatMap (
          name:
          let
            ds = dsSet.${name};
            fullName = "${prefix}/${name}";
            realOpts = lib.filterAttrs (k: _: !(lib.hasPrefix "nixos:" k)) (ds.options or { });
            optProps = lib.mapAttrsToList (k: v: "${k}=${toString v}") realOpts;
            mountProp = lib.optional (
              ds ? mountpoint && ds.mountpoint != null && lib.hasPrefix "/" (toString ds.mountpoint)
            ) "mountpoint=${toString ds.mountpoint}";
            # disko injects a synthetic `__root` dataset per pool to carry the
            # pool's rootFsOptions — that IS the pool root (already created with
            # the pool), never a real child to `zfs create`.  Skip it.
            this = lib.optional (name != "__root") {
              dataset = fullName;
              props = optProps ++ mountProp;
            };
            children =
              if ds ? datasets then
                walk fullName ds.datasets
              else if ds ? children then
                walk fullName ds.children
              else
                [ ];
          in
          this ++ children
        ) (lib.attrNames dsSet);
    in
    walk poolName (poolCfg.datasets or { });

  diskoAllDatasets = lib.concatMap diskoPoolDatasetInventory diskoPoolList;

  # One "<dataset><TAB><k=v> <k=v> …" line per dataset — TAB splits the name from the
  # space-joined property tokens (ZFS property values here never contain spaces).
  zpoolInitDatasetsTable = lib.concatMapStringsSep "\n" (
    e: "${e.dataset}\t${lib.concatStringsSep " " e.props}"
  ) diskoAllDatasets;

  zpoolInitText = ''
    export ZFS_DISK_TANK1="${cfg.bootstrapActivation.dataDisks.tank1}"
    export ZFS_DISK_TANK2="${cfg.bootstrapActivation.dataDisks.tank2}"
    export ZFS_DISK_TANK3="${cfg.bootstrapActivation.dataDisks.tank3}"
    export ZFS_DISK_RECOVER="${cfg.bootstrapActivation.dataDisks.recover}"
    export NDH_ZPOOL_INIT_POOLS=${lib.escapeShellArg (lib.concatStringsSep " " diskoPoolList)}
    export NDH_ZPOOL_INIT_MOUNTPOINTS=${lib.escapeShellArg zpoolInitMountpointsTable}
    export NDH_ZPOOL_INIT_DATASETS=${lib.escapeShellArg zpoolInitDatasetsTable}
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

  # The esp-sync script runs from the upstream finalSystemdBootBuilder
  # (install-systemd-boot.sh), which `switch-to-configuration` invokes via
  # `systemd-run` with a stripped PATH. The source file uses a
  # `#!/usr/bin/env -S bash -euo pipefail` shebang — under a stripped PATH,
  # `/usr/bin/env bash` cannot resolve `bash` and the bootloader install
  # aborts with "env: 'bash': No such file or directory / Failed to install
  # bootloader". Rewrite the shebang to a direct store-path reference so
  # it runs in any PATH context.
  espSyncScript =
    ndhStore.runCommand "esp-sync"
      {
        passAsFile = [ "text" ];
        text = espSyncScriptText;
      }
      ''
        {
          printf '%s\n' '#!${pkgs.bash}/bin/bash'
          tail -n +2 "$textPath"
        } > "$out"
        chmod 0555 "$out"
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

  # repart.d directory for one disk — two rules, fixed across every tank/
  # recover disk. Mounted into the initrd /etc tree so systemd-repart can
  # consume it without a store-path flag at runtime.
  zfsRepartDirFor =
    disk:
    pkgs.runCommand "zfs-repart-${disk}-defs" { } ''
      mkdir -p "$out"
      cat > "$out/10-esp.conf" <<EOF
      [Partition]
      Type=esp
      SizeMinBytes=${toString config.zfsOverlays.diskLayout.espSizeMiB}M
      SizeMaxBytes=${toString config.zfsOverlays.diskLayout.espSizeMiB}M
      EOF
      cat > "$out/20-zfs.conf" <<EOF
      [Partition]
      Type=${config.zfsOverlays.diskLayout.zfsPartitionTypeGuid}
      GrowFileSystem=off
      EOF
    '';

  # One initrd systemd-repart unit per data disk. Ordered before
  # initrd-root-fs.target + sysroot.mount so the partition table has been
  # extended by the time zfs-import scans for pools. Gated by
  # ConditionPathExists so a missing disk is a no-op rather than a failure.
  mkZfsRepartUnit =
    disk:
    let
      devicePath = config.zfsOverlays.bootstrapActivation.dataDisks.${disk};
      deviceUnit = "${utils.escapeSystemdPath devicePath}.device";
    in
    {
      description = "Grow ZFS data-disk partition table on ${disk} (${devicePath})";
      wantedBy = [ "initrd.target" ];
      after = [
        "systemd-udev-settle.service"
        deviceUnit
      ];
      requires = [ deviceUnit ];
      before = [
        "initrd-root-fs.target"
        "sysroot.mount"
      ];
      unitConfig = {
        ConditionPathExists = devicePath;
        DefaultDependencies = false;
      };
      serviceConfig = {
        Type = "oneshot";
        RemainAfterExit = true;
        StandardOutput = "journal+console";
        StandardError = "journal+console";
        ExecStart = ''
          ${config.boot.initrd.systemd.package}/bin/systemd-repart \
            --definitions=/etc/repart.d.${disk} \
            --dry-run=no \
            --empty=refuse \
            --discard=no \
            ${devicePath}
        '';
      };
    };
in
{

  options.zfsOverlays.enable = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Enable ZFS-backed filesystem definitions and boot integration.";
  };
  options.zfsOverlays.repart.enable = lib.mkOption {
    type = lib.types.bool;
    default = true;
    description = ''
      Enable per-data-disk systemd-repart initrd units that pin the ESP to
      its build-time size and grow the ZFS partition to the end of the
      (possibly resized) underlying disk.  One unit per tank/recover disk
      is emitted — the upstream NixOS `boot.initrd.systemd.repart` option
      only models a single device, which is insufficient for the raidz1
      layout, so this implementation authors the units directly.

      Default true so bringup and full-runtime configurations share the
      same invariant: whenever the host-side data disk image is resized
      between boots, partitions auto-grow and zpool-init's
      `zpool online -e` picks up the new sectors.  On an already-sized
      disk the repart run is a cheap no-op (condition check only).
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
  # ZFS snapshots are not currently managed by this module set. Sanoid was
  # configured here historically (took rolling hourly/daily/weekly snapshots
  # of `tank`), but removed once we settled on a per-node-owns-its-data
  # cluster design where replication is not a current requirement.
  #
  # When replication becomes a requirement, the candidate is `zrepl`
  # (continuous TLS-transport replication, daemon model, structured logging)
  # rather than reinstating sanoid + syncoid. See `docs/zfs-snapshot-policy.adoc`
  # for the decision context.
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
      This keeps first boot safe for Tart when extra data disks are not yet attached.
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

    # Per-disk systemd-repart initrd units are declared below alongside the
    # shared storePaths/contents/services merges so we stay under a single
    # boot.initrd.systemd.<attr> assignment per attribute (Nix module system
    # forbids mixing nested + leaf at the same path without mkMerge).

    boot = {
      supportedFilesystems = lib.mkAfter [ "zfs" ];
      initrd = {
        supportedFilesystems = lib.mkAfter (lib.optional config.zfsOverlays.enable "zfs");
      };
      zfs = (
        lib.mkIf config.zfsOverlays.enable {
          forceImportRoot = true;
          # Force import every pool, not just the root.  Without this,
          # `zfs-import-<extraPool>.service` refuses to import on a
          # hostid mismatch — which happens reliably on the
          # bringup→full handoff: the bringup image runs with the
          # placeholder hostid `00000000` and creates the pool labels
          # accordingly; the full system boots with a host-derived
          # hostid that doesn't match the labels, and the non-root
          # extra pools (`recover` etc.) get stuck on
          # `zfs-import-recover.service` failing.  `forceImportAll`
          # makes the import re-stamp the labels with the current
          # hostid on first boot, after which subsequent boots are
          # clean.  See docs/bringup-image-unification.adoc:R2.
          #
          # Trade-off: loses the safety check that catches an
          # accidental import-on-wrong-host.  Acceptable for a
          # single-operator fleet where the operator owns hostid
          # changes deliberately.
          forceImportAll = true;
          devNodes = lib.mkForce "/dev";
          # Derive the import list from the disko config so a new pool added
          # to zfs-disko-config.nix automatically gets its corresponding
          # `zfs-import-<pool>.service` unit.  Mirrors the historic hard-
          # coded `[ "tank" "recover" ]` while staying in sync with the
          # source of truth.
          extraPools = diskoPoolList;
        }
      );

      loader.systemd-boot.extraInstallCommands =
        lib.mkIf (config.boot.loader.systemd-boot.enable && !bringupMode)
          (
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

    # Initrd store-paths: explicitly enumerate scripts + binaries we need in
    # the initrd slice of /nix/store.  NixOS does NOT scan shell scripts for
    # store-path references via make-initrd-ng, so any path a script resolves
    # at runtime has to appear here.
    boot.initrd.systemd.storePaths = lib.mkMerge [
      # boot-entry reconcile service (runs in the initrd after /sysroot/nix/store
      # is mounted).  zpool-init does NOT live in the initrd anymore: NixOS's
      # `zfs-import-<pool>.service` (generated from boot.zfs.extraPools) owns
      # pool import, and our unit runs later in stage-2 after
      # zfs-import.target — see boot.initrd.systemd.services below and the
      # stage-2 `systemd.services.${zpoolInitUnitName}` block further down.
      (lib.mkIf (config.zfsOverlays.enable && (!overlayModeEnabled)) [ initrdBootEntryReconcileScript ])
      (lib.mkIf config.zfsOverlays.repart.enable [
        "${config.boot.initrd.systemd.package}/bin/systemd-repart"
      ])
    ];

    boot.initrd.systemd.contents = lib.mkIf config.zfsOverlays.repart.enable (
      lib.listToAttrs (
        map (disk: {
          name = "/etc/repart.d.${disk}";
          value.source = zfsRepartDirFor disk;
        }) (builtins.attrNames config.zfsOverlays.bootstrapActivation.dataDisks)
      )
    );

    # All initrd systemd services are declared under a single `services = mkMerge`
    # block — Nix module system rejects mixing `services = <attrset>` with
    # `services.<key> = value` at the same path. Each mkMerge element is
    # gated by its own `mkIf`, producing units only when the relevant
    # zfsOverlays flags are enabled.
    #
    # Note: zpool-init used to also run as an initrd unit here, but it
    # duplicated NixOS's own `zfs-import-<pool>.service` (generated from
    # boot.zfs.extraPools) and raced against it — `zpool import` without
    # args only lists unimported pools, so after NixOS imported `tank` the
    # initrd zpool-init saw "not discoverable" and failed the unit.  All
    # responsibilities zpool-init owns (autoexpand + online -e + mountpoint
    # reconcile) need the pool to be already imported, so the stage-2
    # instance (ordered After=zfs-import.target) is the right — and only —
    # placement.
    boot.initrd.systemd.services = lib.mkMerge [
      # Per-disk systemd-repart initrd services (zfsOverlays.repart.enable).
      (lib.mkIf config.zfsOverlays.repart.enable (
        lib.listToAttrs (
          map (disk: {
            name = "zfs-repart-${disk}";
            value = mkZfsRepartUnit disk;
          }) (builtins.attrNames config.zfsOverlays.bootstrapActivation.dataDisks)
        )
      ))

      # Boot-entry reconcile service: runs in the initrd after /sysroot/nix/store
      # is mounted, before initrd-find-nixos-closure. When the ZFS tank disks are
      # provisioned from a newer bringup image than what wrote the ESP boot entries,
      # the init= path in the boot entry may reference a system closure that no
      # longer exists in the ZFS store. This service detects the mismatch and
      # rewrites the systemd-boot .conf entries to point at the system closure
      # that is actually present.
      (lib.mkIf (config.zfsOverlays.enable && (!overlayModeEnabled)) {
        ${bootReconcileUnitName} = {
          description = "Reconcile EFI boot entry with ZFS store system closure";
          unitConfig = {
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
      })
    ];

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

        # Non-overlay mode: runs in stage-2 AFTER NixOS has imported the pools
        # (zfs-import.target is a synchronization point for zfs-import-<pool>
        # services generated from boot.zfs.extraPools).  zpool-init is the
        # autoexpand + `zpool online -e` + mountpoint reconcile owner; pool
        # import itself belongs to NixOS.
        (lib.mkIf (config.zfsOverlays.bootstrapActivation.enable && (!overlayModeEnabled)) {
          description = "Reconcile ZFS pools and mountpoints after import (@codebase)";
          wantedBy = [ contributedTargetName ];
          after = [
            "zfs-import.target"
            "local-fs.target"
          ];
          requires = [ "zfs-import.target" ];
          before = [ zfsNixosInstallServiceName ];

          path = with pkgs; [
            bash
            coreutils
            util-linux
            gawk
            systemd
            zfs
            yq-go
          ];

          serviceConfig = {
            Type = "oneshot";
            RemainAfterExit = true;
            StandardOutput = "journal+console";
            StandardError = "journal+console";
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
