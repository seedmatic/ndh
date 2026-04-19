{ ... }:
{
  # @codebase
  # Lab disko profile for fresh blank attached disks in nixos-installer.
  # Expected devices with current wrapper:
  #   /dev/vdb, /dev/vdc
  # Pool layout (scratch-specific):
  #   tank (mirror) with a minimal dataset tree:
  #     - tank/system/root -> /
  #     - tank/system/nix  -> /nix
  disko.devices = {
    disk = {
      tank1 = {
        type = "disk";
        device = "/dev/vdb";
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
        device = "/dev/vdc";
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

    };

    zpool = {
      tank = {
        type = "zpool";
        mode = "mirror";
        rootFsOptions = {
          acltype = "posixacl";
          atime = "off";
          compression = "zstd";
          xattr = "sa";
          mountpoint = "none";
        };
        options = {
          ashift = "12";
          autotrim = "on";
          bootfs = "tank/system/root";
        };
        datasets = {
          system = {
            type = "zfs_fs";
            options = {
              canmount = "off";
              mountpoint = "none";
            };
          };

          "system/root" = {
            type = "zfs_fs";
            mountpoint = "/";
            options = {
              mountpoint = "legacy";
            };
          };

          "system/nix" = {
            type = "zfs_fs";
            mountpoint = "/nix";
            options = {
              mountpoint = "legacy";
            };
          };
        };
      };
    };
  };
}
