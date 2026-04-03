{
  # WARNING: Never use /net (autofs) as a ZFS dataset mountpoint or overlay source!
  # This will cause ZFS to hang if NFS/autofs is unavailable. Always exclude /net from ZFS overlays.
  config,
  pkgs,
  lib,
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
        depends = [ "/mnt/overlays/${mount}" ];
        options = [ "defaults" ];
        overlay = {
          lowerdir = [ mount ];
          upperdir = (joinMountPoints "/mnt/overlays" mount) + "/upper";
          workdir = (joinMountPoints "/mnt/overlays" mount) + "/workdir";
        };
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
      (pkgs.writeShellScriptBin "bootstrap-zfs" (builtins.readFile ./bootstrap-zfs.sh))
    ];

    systemd = {
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
