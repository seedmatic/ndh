{
  lib,
  disks ? {
    tank1 = "/dev/vdb";
    tank2 = "/dev/vdc";
    tank3 = "/dev/vdd";
    recover = "/dev/vde";
  },
  ...
}:
let
  config = {
    enableConfig = false;
    devices = {
      disk = {
        tank1 = {
          type = "disk";
          device = disks.tank1;
          content = {
            type = "gpt";
            partitions = {
              zfs = {
                size = "100%";
                label = "tank1";
                content = {
                  type = "zfs";
                  pool = "tank";
                };
              };
            };
          };
        };
        tank2 = {
          type = "disk";
          device = disks.tank2;
          content = {
            type = "gpt";
            partitions = {
              zfs = {
                size = "100%";
                label = "tank2";
                content = {
                  type = "zfs";
                  pool = "tank";
                };
              };
            };
          };
        };
        tank3 = {
          type = "disk";
          device = disks.tank3;
          content = {
            type = "gpt";
            partitions = {
              zfs = {
                size = "100%";
                label = "tank3";
                content = {
                  type = "zfs";
                  pool = "tank";
                };
              };
            };
          };
        };
        recover = {
          type = "disk";
          device = disks.recover;
          content = {
            type = "gpt";
            partitions = {
              zfs = {
                size = "100%";
                label = "recover";
                content = {
                  type = "zfs";
                  pool = "recover";
                };
              };
            };
          };
        };
      };

      zpool = {
        tank = {
          type = "zpool";
          mode = "raidz1";
          rootFsOptions = {
            acltype = "posixacl";
            atime = "off";
            compression = "zstd";
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
              options.mountpoint = "legacy";
              mountpoint = "/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.zfs";
            };
            "rke2/control-nodes/peer1" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/peer1/containerd" = {
              type = "zfs_fs";
              options.mountpoint = "legacy";
              mountpoint = "/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.zfs";
            };
            "rke2/control-nodes/peer2" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/peer2/containerd" = {
              type = "zfs_fs";
              options.mountpoint = "legacy";
              mountpoint = "/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.zfs";
            };
            "rke2/control-nodes/peer3" = {
              type = "zfs_fs";
            };
            "rke2/control-nodes/peer3/containerd" = {
              type = "zfs_fs";
              options.mountpoint = "legacy";
              mountpoint = "/var/lib/rancher/rke2/agent/containerd/io.containerd.snapshotter.v1.zfs";
            };
            "nerd" = {
              type = "zfs_fs";
            };
            "nerd/nix" = {
              type = "zfs_fs";
              mountpoint = "/nix";
              options = {
                "nixos:mount-overlay" = "true";
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
          };
        };
        recover = {
          type = "zpool";
          mode = "";
          rootFsOptions = {
            acltype = "posixacl";
            atime = "off";
            compression = "zstd";
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
      overlayEnabled =
        (dataset.options or { }) ? "nixos:mount-overlay"
        && (dataset.options."nixos:mount-overlay" == "true");
      dsWithOpts = addDatasetOptions dataset;
    in
    if overlayEnabled then
      dsWithOpts
      // {
        postMountHook = ''
          mkdir -p "/mnt${dataset.mountpoint}/workdir"
          mkdir -p "/mnt${dataset.mountpoint}/upper"
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
