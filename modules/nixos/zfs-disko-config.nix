{
  lib,
  hostProfile ? { },
  installRootMountPoint ? "/mnt/zfs-root",
  diskImageSize ? "100G",
  # Dedicated EFI-only boot disk — holds systemd-boot + kernel + initrd only.
  # All ZFS data lives on the tank disks, keeping them uniform and seedable.
  bootDiskImageSize ? "600M",
  espStartMiB ? 1,
  espSizeMiB ? 512,
  zfsStartMiB ? 514,
  zfsPoolDiskMap ? null,
  disks ? {
    # boot: dedicated EFI boot disk (vda). ZFS data disks start at vdb.
    # This keeps all tank disks uniform — no dual boot+data role on tank1.
    boot = "/dev/vda";
    tank1 = "/dev/vdb";
    tank2 = "/dev/vdc";
    tank3 = "/dev/vdd";
    recover = "/dev/vde";
  },
  ...
}:
let
  zfsPoolDiskMapEffective =
    if zfsPoolDiskMap != null then zfsPoolDiskMap else import ./zfs-pool-disk-map.nix;
  zstdLevel = hostProfile.nixosZstdCompressionLevel or 1;
  zfsCompression = "zstd-${toString zstdLevel}";
  espEndMiB = espStartMiB + espSizeMiB;
  # GPT type code BF01 shorthand expanded to canonical Solaris/ZFS GUID.
  zfsPartitionType = "6A898CC3-1DD2-11B2-99A6-080020736631";

  mkEspPartition =
    {
      label,
      mountpoint ? null,
    }:
    {
      start = "${toString espStartMiB}MiB";
      end = "${toString espEndMiB}MiB";
      inherit label;
      type = "EF00";
      content = {
        type = "filesystem";
        format = "vfat";
      }
      // lib.optionalAttrs (mountpoint != null) {
        inherit mountpoint;
      };
    };

  # Dedicated EFI-only boot disk. Holds systemd-boot + kernel + initrd.
  # No ZFS partition — all data lives on the uniform tank disks.
  mkBootDisk =
    { device }:
    {
      type = "disk";
      inherit device;
      imageSize = bootDiskImageSize;
      content = {
        type = "gpt";
        partitions = {
          esp = mkEspPartition {
            label = "esp-boot";
            mountpoint = "/boot";
          };
        };
      };
    };

  mkPoolDisk =
    {
      name,
      device,
      espLabel,
      pool,
      espMountpoint ? null,
    }:
    {
      type = "disk";
      inherit device;
      imageSize = diskImageSize;
      content = {
        type = "gpt";
        partitions = {
          esp = mkEspPartition {
            label = espLabel;
            mountpoint = espMountpoint;
          };
          zfs = {
            start = "${toString zfsStartMiB}MiB";
            end = "-1MiB";
            label = name;
            type = zfsPartitionType;
            content = {
              type = "zfs";
              inherit pool;
            };
          };
        };
      };
    };

  zfsPoolDisks = lib.listToAttrs (
    map (spec: {
      name = spec.disk;
      value = mkPoolDisk {
        name = spec.disk;
        espLabel = "esp-${spec.disk}";
        device = disks.${spec.disk};
        pool = spec.pool;
      };
    }) zfsPoolDiskMapEffective
  );

  config = {
    enableConfig = false;
    devices = {
      disk =
        zfsPoolDisks
        # Include dedicated boot disk only when provided in disks attrset.
        // lib.optionalAttrs (disks ? boot) {
          boot = mkBootDisk { device = disks.boot; };
        };

      zpool = {
        tank = {
          type = "zpool";
          mode = "raidz1";
          rootFsOptions = {
            acltype = "posixacl";
            atime = "off";
            compression = zfsCompression;
            xattr = "sa";
          };
          options = {
            ashift = "12";
          };
          datasets = {
            "rke2" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/master" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/master/containerd" = {
              type = "zfs_fs";
              # Owned by the incus guest, not the nerd host — legacy ZFS property
              # prevents auto-mount; no disko mountpoint so it never enters host fstab.
              options.mountpoint = "legacy";
            };
            "rke2/control-nodes/peer1" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/peer1/containerd" = {
              type = "zfs_fs";
              options.mountpoint = "legacy";
            };
            "rke2/control-nodes/peer2" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/peer2/containerd" = {
              type = "zfs_fs";
              options.mountpoint = "legacy";
            };
            "rke2/control-nodes/peer3" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/peer3/containerd" = {
              type = "zfs_fs";
              options.mountpoint = "legacy";
            };
            "nerd" = {
              type = "zfs_fs";
            };
            "nerd/root" = {
              type = "zfs_fs";
              mountpoint = "/";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/nix" = {
              type = "zfs_fs";
              mountpoint = "/nix";
              options = {
                "nixos:mount-overlay" = "true";
                # Nix store files are typically small (<64K) and write-once.
                # 16K recordsize reduces write amplification vs the 128K default.
                # primarycache=metadata keeps ARC free of data blocks that are
                # never re-read during install (only metadata lookups matter).
                # sync intentionally inherits from pool: the install script sets
                # sync=disabled on the pool during bringup and restores
                # sync=standard before export — a local property here would
                # survive the pool-level restore and stay disabled at runtime.
                recordsize = "16K";
                primarycache = "metadata";
              };
            };
            "nerd/nix/builds" = {
              type = "zfs_fs";
              mountpoint = "/nix/var/nix/builds";
              options = {
                # Build dirs hold large sparse raw QEMU disk images (3-4G per vdev).
                # 1M recordsize aligns with QEMU virtio-blk sequential write patterns.
                # compression=off: guest ZFS already compresses; double-zstd is pure waste.
                # sync=disabled: build dirs are ephemeral — losing them on crash is fine.
                # primarycache=none: these files are never re-read; keep ARC free.
                recordsize = "1M";
                compression = "off";
                sync = "disabled";
                primarycache = "none";
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/var" = {
              type = "zfs_fs";
            };
            "nerd/var/cache" = {
              type = "zfs_fs";
              mountpoint = "/var/cache";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/var/log" = {
              type = "zfs_fs";
              mountpoint = "/var/log";
              options = {
                "nixos:mount-overlay" = "true";
              };
            };
            "nerd/var/lib" = {
              type = "zfs_fs";
            };
            "nerd/var/lib/buildkit" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/buildkit";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/var/lib/containerd" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/containerd";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            # "nerd/var/lib/docker" = {
            #   type = "zfs_fs";
            #   mountpoint = "/var/lib/docker";
            #   options = { "nixos:mount-overlay" = "false"; };
            # };
            "nerd/var/lib/incus" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/incus";
              options = {
                "nixos:mount-overlay" = "true";
              };
            };
            "nerd/var/lib/lxc" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/lxc";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/var/lib/nixos-containers" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/nixos-containers";
              options = {
                "nixos:mount-overlay" = "true";
              };
            };
            "nerd/var/lib/nix-snapshotter" = {
              type = "zfs_fs";
              mountpoint = "/var/lib/nix-snapshotter";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/var/tmp" = {
              type = "zfs_fs";
              mountpoint = "/var/tmp";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/persist" = {
              type = "zfs_fs";
              mountpoint = "/persist";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
            "nerd/srv" = {
              type = "zfs_fs";
              mountpoint = "/srv";
              options = {
                "nixos:mount-overlay" = "false";
              };
            };
          };
        };
        recover = {
          type = "zpool";
          mode = "";
          rootFsOptions = {
            acltype = "posixacl";
            atime = "off";
            compression = zfsCompression;
            xattr = "sa";
          };
          options = {
            ashift = "12";
          };
          datasets = {
            "recover" = {
              type = "zfs_fs";
            };
          };
        };
      };
    };
  };

  addDatasetOptions =
    dataset:
    let
      # Merge or create the options attribute, always setting auto-snapshot false
      opts = (dataset.options or { }) // {
        "com.sun:auto-snapshot" = "false";
      };
      dsWithOpts = dataset // {
        options = opts;
      };
    in
    dsWithOpts;

  addPostMountHook =
    dataset:
    let
      hasExplicitMountpoint = dataset ? mountpoint && dataset.mountpoint != null;
      overlayEnabled =
        (dataset.options or { }) ? "nixos:mount-overlay"
        && (dataset.options."nixos:mount-overlay" == "true");
      dsWithOpts = addDatasetOptions dataset;
    in
    if overlayEnabled then
      dsWithOpts
      // {
        postMountHook = ''
          mkdir -p "${installRootMountPoint}${dataset.mountpoint}/workdir"
          mkdir -p "${installRootMountPoint}${dataset.mountpoint}/upper"
        '';
      }
    else
      dsWithOpts;

  datasetsWithHooks =
    datasets:
    lib.mapAttrs (
      _: ds:
      let
        ds' = if ds ? datasets then ds // { datasets = datasetsWithHooks ds.datasets; } else ds;
      in
      addPostMountHook ds'
    ) datasets;

  zpoolWithDatasetHooks = lib.mapAttrs (
    poolName: pool:
    pool
    // {
      datasets = datasetsWithHooks (pool.datasets or { });
    }
  ) config.devices.zpool;

  configWithDatasetsHooks =
    config:
    config
    // {
      devices = config.devices // {
        zpool = zpoolWithDatasetHooks;
      };
    };
in
(configWithDatasetsHooks config)
