{
  # WARNING: Never use /net (autofs) as a ZFS dataset mountpoint or overlay source!
  # This will cause ZFS to hang if NFS/autofs is unavailable. Always exclude /net from ZFS overlays.
  config,
  pkgs,
  lib,
  ndh,
  ...
}:

let
  cfg = config.zfsOverlays;
  hostId = config.networking.hostId;

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

  mountpointMap = builtins.traceVerbose ''
    -- mountpointMap --
    ${builtins.toJSON _mountpointMap}
    --'' _mountpointMap;

  mountPoints = lib.attrNames mountpointMap;

  _overlayMountPoints = lib.filter (
    mp:
    let
      ds = mountpointMap.${mp};
    in
    ds.options ? "nixos:mount-overlay" && ds.options."nixos:mount-overlay" == "true"
  ) mountPoints;

  overlayMountPoints = builtins.traceVerbose ''
    -- overlayMountPoints --
    ${builtins.toJSON _overlayMountPoints}
    --'' _overlayMountPoints;

  _zfsMountPoints = lib.filter (
    mp:
    let
      ds = mountpointMap.${mp};
    in
    !(ds.options ? "nixos:mount-overlay" && ds.options."nixos:mount-overlay" == "true")
  ) mountPoints;

  zfsMountPoints = builtins.traceVerbose ''
    -- zfsMountPoints --
    ${builtins.toJSON _zfsMountPoints}
    --'' _zfsMountPoints;

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

  fileSystems =
    let
      _value = zfsOverlayFileSystems // overlayFileSystems;
      _json = (builtins.toJSON _value);
    in
    (builtins.traceVerbose ''
      -- config.fileSystems --
      ${_json}
      --'' _value);

  diskoModulePinned = ndh.store.writeText "disko-module-pinned.nix" ''
    { lib, ... }:
    {
      disko = import ${./disko-config.nix} { inherit lib; };
    }
  '';

  zpoolInit = pkgs.writeShellScriptBin "zpool-init" ''
    export DISKO_NIX_DEFAULT="${diskoModulePinned}"
    ${builtins.readFile ./zfs.d/zpool-init.sh}
  '';

in
{

  options.zfsOverlays.override = lib.mkOption {
    type = lib.types.bool;
    default = false;
    description = "Whether to override fileSystems definitions at initial boot.";
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
  options.zfsOverlays.bootstrapActivation.requiredDevices = lib.mkOption {
    type = lib.types.listOf lib.types.str;
    default = [
      "/dev/vdb"
      "/dev/vdc"
      "/dev/vdd"
      "/dev/vde"
    ];
    description = ''
      Block devices that must be present before running bootstrap datastore provisioning.
      This keeps first boot safe for Tart/Lima when extra data disks are not yet attached.
    '';
  };
  config = {

    networking.hostId = lib.mkDefault hostId;

    boot = {
      supportedFilesystems = (lib.mkAfter { zfs = lib.mkForce true; });
      initrd = {
        supportedFilesystems = lib.mkAfter { zfs = (lib.mkForce config.zfsOverlays.override); };
      };
      zfs = (
        lib.mkIf config.zfsOverlays.override {
          forceImportRoot = false;
          devNodes = lib.mkForce "/dev/disk/by-partlabel";
          extraPools = [
            "tank"
            "recover"
          ];
        }
      );
    };

    # Only enable services and mount filesystems if override is true
    services.zfs = {
      autoScrub.enable = true;
      trim.enable = true;
    };

    services.sanoid = lib.mkIf config.zfsOverlays.sanoid.enable {
      enable = true;
      datasets = config.zfsOverlays.sanoid.datasets;
    };

    fileSystems = (
      lib.mkIf config.zfsOverlays.override (
        lib.mkMerge [ (lib.mapAttrs (_: fs: lib.mkForce fs) fileSystems) ]
      )
    );

    # Only add extra scripts and shutdown logic if override is true
    environment.systemPackages = [
      pkgs.zfs
      zpoolInit
    ];

    systemd = {
      services."io-nxmatic-nix-darwin-home-zpool-init" = lib.mkIf config.zfsOverlays.bootstrapActivation.enable {
        description = "Idempotent one-shot ZFS disk/datastore provisioning (@codebase)";
        wantedBy = [ "zfs-import.target" ];
        wants = [ "systemd-udev-settle.service" ];
        before = [
          "zfs-import.target"
          "zfs-import-cache.service"
          "zfs-import-scan.service"
          "zfs-mount.service"
        ];
        after = [
          "systemd-udev-settle.service"
        ];

        path = with pkgs; [
          bash
          coreutils
          util-linux
          gawk
          zfs
          disko
        ];

        serviceConfig = {
          Type = "oneshot";
          RemainAfterExit = true;
          ExecCondition = ndh.store.writeShellScript "zpool-init-devices-check" ''
            set -eu

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

            exec ${zpoolInit}/bin/zpool-init
          '';
          TimeoutStartSec = "30min";
        };

        unitConfig = {
          X-StopOnRemoval = false;
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
