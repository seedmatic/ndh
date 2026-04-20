# @codebase
# Minimal single-disk bootstrap image helper for serial/bootloader validation.
{
  lib,
  pkgs,
  config,
  diskSize ? 8192,
  memSize ? 1536,
  includeChannel ? false,
  useQemuImg ? false,
  qemuFallbackInVm ? true,
  name ? "nixos-bootstrap-image",
  rootFsType ? "btrfs",
  rootFsLabel ? "nixos",
  rootFsMountOptions ? [ ],
  postVM ? "",
}:
let
  qemuCommon = import (pkgs.path + "/nixos/lib/qemu-common.nix") {
    inherit lib pkgs;
  };

  defaultQemuCommand = qemuCommon.qemuBinary pkgs.qemu_kvm;

  fallbackQemuCommand =
    builtins.replaceStrings [ "accel=kvm:tcg" "accel=hvf:tcg" ] [ "accel=tcg" "accel=tcg" ]
      defaultQemuCommand;

  vmToolsBase =
    if qemuFallbackInVm then
      pkgs.vmTools.override {
        customQemu = fallbackQemuCommand;
      }
    else
      pkgs.vmTools;

  channelSources =
    let
      nixpkgsSource = lib.cleanSource pkgs.path;
    in
    pkgs.runCommand "nixos-${config.system.nixos.version}" { } ''
      mkdir -p "$out"
      cp -prd ${nixpkgsSource.outPath} "$out/nixos"
      chmod -R u+w "$out/nixos"
      if [ ! -e "$out/nixos/nixpkgs" ]; then
        ln -s . "$out/nixos/nixpkgs"
      fi
      rm -rf "$out/nixos/.git"
      echo -n ${config.system.nixos.versionSuffix} > "$out/nixos/.version-suffix"
    '';

  closureInfo = pkgs.closureInfo {
    rootPaths = [ config.system.build.toplevel ] ++ (lib.optional includeChannel channelSources);
  };

  modulesTree = pkgs.aggregateModules (
    with config.boot;
    [
      kernelPackages.kernel
      (lib.getOutput "modules" kernelPackages.kernel)
    ]
  );

  tools = lib.makeBinPath (
    with pkgs;
    [
      btrfs-progs
      coreutils
      nixos-enter
      config.system.build.nixos-install
      dosfstools
      e2fsprogs
      gptfdisk
      nix
      parted
      util-linux
    ]
  );

  fileSystemsCfgFile = pkgs.writeText "bootstrap-filesystems.nix" ''
    {
      fileSystems."/" = {
        device = "/dev/disk/by-label/${rootFsLabel}";
        fsType = "${rootFsType}";
        options = ${builtins.toJSON rootFsMountOptions};
      };
      fileSystems."/boot" = {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
      };
    }
  '';
in
(vmToolsBase.override {
  rootModules = [
    "btrfs"
    "9p"
    "9pnet_virtio"
    "virtio_blk"
    "virtio_pci"
    "virtiofs"
  ];
  kernel = modulesTree;
}).runInLinuxVM
  (
    pkgs.runCommand name
      {
        QEMU_OPTS = "-drive file=$bootstrapDiskImage,if=virtio,format=raw,cache=unsafe,werror=report";
        inherit memSize;

        preVM = ''
          PATH="$PATH:${pkgs.qemu_kvm}/bin"
          mkdir "$out"

          create_raw_disk() {
            local file="$1"
            local size_mib="$2"
            if ${if useQemuImg then "true" else "false"}; then
              qemu-img create -f raw "$file" ''${size_mib}M
            else
              truncate -s ''${size_mib}M "$file"
            fi
          }

          bootstrapDiskImage=disk.raw
          create_raw_disk "$bootstrapDiskImage" ${toString diskSize}
        '';

        postVM = ''
          mv "$bootstrapDiskImage" "$out/nixos.img"

          set -x
          ${postVM}
        '';
      }
      ''
        export PATH=${tools}:$PATH
        set -x

        cp -sv /dev/vda /dev/sda
        cp -sv /dev/vda /dev/xvda

        root_parted_fs="ext4"
        case "${rootFsType}" in
          btrfs)
            root_parted_fs="btrfs"
            ;;
          ext4)
            root_parted_fs="ext4"
            ;;
          *)
            echo "[bootstrap-image][ERROR] unsupported rootFsType: ${rootFsType}" >&2
            exit 1
            ;;
        esac

        parted --script /dev/vda -- \
          mklabel gpt \
          mkpart ESP fat32 1MiB 1025MiB \
          set 1 esp on \
          align-check optimal 1 \
          mkpart primary "$root_parted_fs" 1025MiB -1MiB \
          align-check optimal 2 \
          print

        mkfs.vfat -n ESP /dev/vda1

        case "${rootFsType}" in
          btrfs)
            mkfs.btrfs -f -L ${rootFsLabel} /dev/vda2
            ;;
          ext4)
            mkfs.ext4 -F -L ${rootFsLabel} /dev/vda2
            ;;
          *)
            echo "[bootstrap-image][ERROR] unsupported mkfs for rootFsType: ${rootFsType}" >&2
            exit 1
            ;;
        esac

        mkdir -p /mnt
        mount /dev/vda2 /mnt
        mkdir -p /mnt/boot /mnt/etc/nixos
        mount /dev/vda1 /mnt/boot

        cat ${fileSystemsCfgFile} > /mnt/etc/nixos/configuration.nix

        export NIX_STATE_DIR=$TMPDIR/state
        nix-store --load-db < ${closureInfo}/registration

        nixos-install \
          --root /mnt \
          --no-root-passwd \
          --system ${config.system.build.toplevel} \
          --substituters "" \
          ${lib.optionalString includeChannel "--channel ${channelSources}"}

        umount /mnt/boot
        umount /mnt
      ''
  )
