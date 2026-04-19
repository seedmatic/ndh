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
  name ? "nixos-bootstrap-image",
  postVM ? "",
}:
let
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
        device = "/dev/disk/by-label/nixos";
        fsType = "ext4";
      };
      fileSystems."/boot" = {
        device = "/dev/disk/by-label/ESP";
        fsType = "vfat";
      };
    }
  '';
in
(pkgs.vmTools.override {
  rootModules = [
    "9p"
    "9pnet_virtio"
    "virtio_blk"
    "virtio_pci"
    "virtiofs"
  ];
  kernel = modulesTree;
}).runInLinuxVM (
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

      parted --script /dev/vda -- \
        mklabel gpt \
        mkpart no-fs 1MiB 2MiB \
        set 1 bios_grub on \
        align-check optimal 1 \
        mkpart ESP fat32 2MiB 1026MiB \
        set 2 esp on \
        align-check optimal 2 \
        mkpart primary ext4 1026MiB -1MiB \
        align-check optimal 3 \
        print

      mkfs.vfat -n ESP /dev/vda2
      mkfs.ext4 -F -L nixos /dev/vda3

      mkdir -p /mnt
      mount /dev/vda3 /mnt
      mkdir -p /mnt/boot /mnt/etc/nixos
      mount /dev/vda2 /mnt/boot

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
