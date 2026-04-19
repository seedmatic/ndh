# @codebase
# Experimental helper for a 3-disk root pool image.
# Inspired by nixpkgs/nixos/lib/make-multi-disk-zfs-image.nix and intentionally
# scoped for sandbox experiments.
{
  lib,
  pkgs,
  config,
  bootSize ? 1024,
  rootDiskSize ? 2048,
  rootPoolName ? "tank",
  rootPoolMode ? "raidz1",
  rootPoolProperties ? {
    autoexpand = "on";
    ashift = "12";
  },
  rootPoolFilesystemProperties ? {
    acltype = "posixacl";
    atime = "off";
    compression = "zstd";
    mountpoint = "legacy";
    xattr = "sa";
  },
  datasets ? {
    "tank/root" = { mount = "/"; };
  },
  # Keep memory modest for local lab hosts; increase when needed.
  memSize ? 1536,
  # Fast-lab default: skip embedding nixpkgs channel copy in the image.
  includeChannel ? false,
  # Fast-lab default: use truncate for sparse raw disk files.
  # Set true to force qemu-img creation.
  useQemuImg ? false,
  name ? "nixos-zfs-raidz1-image",
  postVM ? "",
}:
let
  rootDevices = [ "/dev/vdb" "/dev/vdc" "/dev/vdd" ];
  rootDiskFiles = [ "root-1.raw" "root-2.raw" "root-3.raw" ];

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
      kernelPackages.${pkgs.zfs.kernelModuleAttribute}
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
      zfs
    ]
  );

  hasDefinedMount = dataset: ((dataset.mount or null) != null);

  stringifyProperties =
    prefix: properties:
    lib.concatStringsSep " \\\n" (
      lib.mapAttrsToList (
        property: value: "${prefix} ${lib.escapeShellArg property}=${lib.escapeShellArg value}"
      ) properties
    );

  createDatasets =
    let
      datasetList = lib.mapAttrsToList lib.nameValuePair datasets;
      sorted = lib.sort (left: right: (lib.stringLength left.name) < (lib.stringLength right.name)) datasetList;
      cmd =
        { name, value }:
        let
          properties = stringifyProperties "-o" (value.properties or { });
        in
        "zfs create -p ${properties} ${name}";
    in
    lib.concatMapStringsSep "\n" cmd sorted;

  mountDatasets =
    let
      datasetList = lib.mapAttrsToList lib.nameValuePair datasets;
      mounts = lib.filter ({ value, ... }: hasDefinedMount value) datasetList;
      sorted = lib.sort (left: right: (lib.stringLength left.value.mount) < (lib.stringLength right.value.mount)) mounts;
      cmd =
        { name, value }:
        ''
          mkdir -p /mnt${lib.escapeShellArg value.mount}
          mount -t zfs ${name} /mnt${lib.escapeShellArg value.mount}
        '';
    in
    lib.concatMapStringsSep "\n" cmd sorted;

  unmountDatasets =
    let
      datasetList = lib.mapAttrsToList lib.nameValuePair datasets;
      mounts = lib.filter ({ value, ... }: hasDefinedMount value) datasetList;
      sorted = lib.sort (left: right: (lib.stringLength left.value.mount) > (lib.stringLength right.value.mount)) mounts;
      cmd =
        { value, ... }:
        ''
          umount /mnt${lib.escapeShellArg value.mount}
        '';
    in
    lib.concatMapStringsSep "\n" cmd sorted;

  fileSystemsCfgFile =
    let
      mountable = lib.filterAttrs (_: value: hasDefinedMount value) datasets;
    in
    pkgs.runCommand "filesystem-config.nix"
      {
        buildInputs = with pkgs; [ jq nixpkgs-fmt ];
        filesystems = builtins.toJSON {
          fileSystems = lib.mapAttrs' (dataset: attrs: {
            name = attrs.mount;
            value = {
              fsType = "zfs";
              device = "${dataset}";
            };
          }) mountable;
        };
        passAsFile = [ "filesystems" ];
      }
      ''
        (
          echo "builtins.fromJSON '''"
          jq . < "$filesystemsPath"
          echo "'''"
        ) > "$out"

        nixpkgs-fmt "$out"
      '';

  zpoolVdevSpec = lib.concatMapStringsSep " " lib.escapeShellArg ([ rootPoolMode ] ++ rootDevices);

  image =
    (pkgs.vmTools.override {
      rootModules = [
        "9p"
        "9pnet_virtio"
        "virtio_blk"
        "virtio_pci"
        "virtiofs"
        "zfs"
      ];
      kernel = modulesTree;
    }).runInLinuxVM (
      pkgs.runCommand name
        {
          QEMU_OPTS =
            "-drive file=$bootDiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
            + " -drive file=$rootDiskImage1,if=virtio,format=raw,cache=unsafe,werror=report"
            + " -drive file=$rootDiskImage2,if=virtio,format=raw,cache=unsafe,werror=report"
            + " -drive file=$rootDiskImage3,if=virtio,format=raw,cache=unsafe,werror=report";

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

            bootDiskImage=boot.raw
            create_raw_disk "$bootDiskImage" ${toString bootSize}

            rootDiskImage1=${builtins.elemAt rootDiskFiles 0}
            rootDiskImage2=${builtins.elemAt rootDiskFiles 1}
            rootDiskImage3=${builtins.elemAt rootDiskFiles 2}
            create_raw_disk "$rootDiskImage1" ${toString rootDiskSize}
            create_raw_disk "$rootDiskImage2" ${toString rootDiskSize}
            create_raw_disk "$rootDiskImage3" ${toString rootDiskSize}
          '';

          postVM = ''
            mv "$bootDiskImage" "$out/nixos.boot.img"
            mv "$rootDiskImage1" "$out/nixos.root-1.img"
            mv "$rootDiskImage2" "$out/nixos.root-2.img"
            mv "$rootDiskImage3" "$out/nixos.root-3.img"

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
            mkpart ESP fat32 2MiB -1MiB \
            align-check optimal 2 \
            print

          zpool create \
            ${stringifyProperties "  -o" rootPoolProperties} \
            ${stringifyProperties "  -O" rootPoolFilesystemProperties} \
            ${rootPoolName} ${zpoolVdevSpec}

          ${createDatasets}
          ${mountDatasets}

          mkdir -p /mnt/boot
          mkfs.vfat -n ESP /dev/vda2
          mount /dev/vda2 /mnt/boot

          mkdir -p /mnt/etc/nixos
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
          ${unmountDatasets}

          zpool export ${rootPoolName}
        ''
    );
in
image
