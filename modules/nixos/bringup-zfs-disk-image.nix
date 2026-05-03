{
  lib,
  pkgs,
  config,
  installSystemPath ? config.system.build.toplevel,
  # Production runtime system closure to include in the bringup image store.
  # zfs-nixos-install.service uses this as NDH_NIXOS_INSTALL_SYSTEM_PATH to
  # install the full system without network access at first boot.
  runtimeSystemPath ? null,
  zpoolDiskSize ? 1536, # 1.5GiB
  # Dedicated EFI boot disk size — holds only systemd-boot + kernel + initrd.
  bootDiskSize ? 600, # 600MiB (512MiB ESP + GPT overhead)
  memSize ? 1536,
  vmCpuCores ? 4,
  includeChannel ? false,

  qemuFallbackInVm ? null, # deprecated, no-op — accel detected at build time via /dev/kvm
  name ? "nixos-bringup-zfs-disk-images",
  # When false, the nested QEMU guest has no network at all.
  nestedQemuNetworkEnable ? true,
  postVM ? "",
}:
let
  zfsPoolDiskMap = import ./zfs-pool-disk-map.nix;
  espStartMiB = 1;
  espSizeMiB = 512;
  zfsStartMiB = espStartMiB + espSizeMiB + 1;
  virtioDeviceNameAt = index: "vd${lib.substring index 1 "bcdefghijklmnopqrstuvwxyz"}";
  zfsDiskDeviceMap = lib.listToAttrs (lib.imap0 (index: entry: {
    name = entry.disk;
    value = "/dev/${virtioDeviceNameAt index}";
  }) zfsPoolDiskMap);
  zfsPoolDiskMapJson = builtins.toJSON zfsPoolDiskMap;
  zfsPoolDiskMapJsonFile = pkgs.writeText "zfs-pool-disk-map.json" zfsPoolDiskMapJson;
  diskoDisksAttrLines = lib.concatStringsSep "\n          " (
    map (entry: "${entry.disk} = \"${zfsDiskDeviceMap.${entry.disk}}\";") zfsPoolDiskMap
  );
  qemuAdditionalDriveOpts = lib.concatStringsSep " " (
    map
      (entry: "-drive file=${entry.disk}DiskImage,if=virtio,format=raw,cache=unsafe,werror=report")
      zfsPoolDiskMap
  );
  preVmDiskImageVars = lib.concatStringsSep "\n          " (
    map (entry: "${entry.disk}DiskImage=${entry.disk}.raw") zfsPoolDiskMap
  );
  preVmCreateRawDisks = lib.concatStringsSep "\n          " (
    map (entry: "bringup::create_raw_disk \"${entry.disk}DiskImage\" ${toString zpoolDiskSize}") zfsPoolDiskMap
  );
  postVmMoveDiskImages = lib.concatStringsSep "\n          " (
    map (entry: "mv \"${entry.disk}DiskImage\" \"$out/${entry.disk}.img\"") zfsPoolDiskMap
  );
  bringupCommon = import ./bringup-disk-image-common.nix {
    inherit
      lib
      pkgs
      nestedQemuNetworkEnable
      ;
  };
  bringupCommonScript = ./bringup-disk-image-common.sh;

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
    rootPaths =
      [ installSystemPath ]
      ++ (lib.optional (runtimeSystemPath != null) runtimeSystemPath)
      ++ (lib.optional includeChannel channelSources);
  };

  # boot.zfs.package is userspace (zfs-user-*). The kernel module package must
  # come from linuxPackages.${pkgs.zfs.kernelModuleAttribute}.
  kernelZfsModulePackage = builtins.getAttr pkgs.zfs.kernelModuleAttribute config.boot.kernelPackages;

  modulesTree = pkgs.aggregateModules (
    with config.boot;
    [
      kernelPackages.kernel
      (lib.getOutput "modules" kernelPackages.kernel)
      kernelZfsModulePackage
    ]
  );

  # Packages for the bringup shell PATH. The forensic/disk tools are sourced from
  # the shared initrd-emergency-tools.nix to stay in sync with what the initrd
  # emergency shell provides at runtime.
  initrdEmergencyTools = import ./initrd-emergency-tools.nix pkgs;
  initrdEmergencyPackages = initrdEmergencyTools.packages;

  tools = lib.makeBinPath (
    with pkgs;
    [
      coreutils
      disko
      yq-go
      nixos-enter
      config.system.build.nixos-install
      dosfstools
      nix
      parted
      procps # ps, top, free, vmstat
      htop
      iotop-c # per-process I/O monitor (C rewrite, works without Python)
      sysstat # iostat, mpstat, pidstat, sar
      lsof
      shadow
      strace
      systemd
    ]
    ++ initrdEmergencyPackages
  );

  diskoConfigFile = pkgs.writeText "bringup-zfs-disko.nix" ''
    { lib, ... }:
    let
      cfg = import ${./zfs-disko-config.nix} {
        inherit lib;
        zfsPoolDiskMap = builtins.fromJSON (builtins.readFile ${zfsPoolDiskMapJsonFile});
        installRootMountPoint = "/mnt/zfs-root";
        diskImageSize = "${toString zpoolDiskSize}M";
        bootDiskImageSize = "${toString bootDiskSize}M";
        espStartMiB = ${toString espStartMiB};
        espSizeMiB = ${toString espSizeMiB};
        zfsStartMiB = ${toString zfsStartMiB};
        disks = {
          nixos = "/dev/vda";
          ${diskoDisksAttrLines}
        };
      };
    in
    {
      disko.devices = cfg.devices;
    }
  '';

  diskoFormatScript = pkgs.callPackage "${pkgs.disko}/share/disko/cli.nix" {
    inherit lib;
    mode = "format";
    diskoFile = diskoConfigFile;
    rootMountPoint = "/mnt/zfs-root";
    noDeps = true;
  };

  diskoMountScript = pkgs.callPackage "${pkgs.disko}/share/disko/cli.nix" {
    inherit lib;
    mode = "mount";
    diskoFile = diskoConfigFile;
    rootMountPoint = "/mnt/zfs-root";
    noDeps = true;
  };

  diskoUnmountScript = pkgs.callPackage "${pkgs.disko}/share/disko/cli.nix" {
    inherit lib;
    mode = "unmount";
    diskoFile = diskoConfigFile;
    rootMountPoint = "/mnt/zfs-root";
    noDeps = true;
  };

  diskoFormatExe = lib.getExe diskoFormatScript;
  diskoMountExe = lib.getExe diskoMountScript;
  diskoUnmountExe = lib.getExe diskoUnmountScript;

  zfsBringupInstallScript = pkgs.runCommand "io.nxmatic.nix-darwin-home-bringup-zfs-disk-images-install" { } ''
    install -Dm755 ${
      pkgs.replaceVars ./zfs.d/bringup-zfs-disk-images-install.sh {
        bringupCommonScript = "${bringupCommonScript}";
        diskoFormatExe = "${diskoFormatExe}";
        diskoMountExe = "${diskoMountExe}";
        diskoUnmountExe = "${diskoUnmountExe}";
        closureRegistration = "${closureInfo}/registration";
        nixosInstall = "${config.system.build.nixos-install}/bin/nixos-install";
        systemToplevel = "${installSystemPath}";
        systemdLibUdevd = "${pkgs.systemd}/lib/systemd/systemd-udevd";
        channelFlag = if includeChannel then "--channel ${channelSources}" else "";
        bootSizePolicyNote = builtins.toJSON "ZFS bringup artifacts generated from canonical zfs-pool-disk-map definitions.";
      }
    } "$out/bin/bringup-zfs-disk-images-install"
  '';

  nestedQemuNetOpts = bringupCommon.nestedQemuNetOpts;
in
(bringupCommon.vmToolsBase.override {
  rootModules = [
    "zfs"
    "fuse"
    "9p"
    "9pnet_virtio"
    "virtio_blk"
    "virtio_pci"
    "virtio_console"
    "virtiofs"
  ];
  kernel = modulesTree;
}).runInLinuxVM
  (
    pkgs.runCommand name
      {
        QEMU_OPTS = lib.concatStringsSep " " [
          "-drive file=$bootDiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          qemuAdditionalDriveOpts
          nestedQemuNetOpts
        ];
        NIX_BUILD_CORES = toString vmCpuCores;
        inherit memSize;

        preVM = ''
          set -x
          PATH="$PATH:${pkgs.qemu_kvm}/bin"
          mkdir "$out"

          QEMU_OPTS="$QEMU_OPTS -device virtio-serial -chardev socket,id=shell-sock,path=$PWD/shell.sock,server=on,wait=off -device virtconsole,chardev=shell-sock,name=shell"

          echo >&2 "[bringup] debug shell ready once QEMU starts:"
          echo >&2 "[bringup]   sudo socat UNIX-CONNECT:$PWD/shell.sock -,raw,echo=0,escape=0x1d"
          echo >&2 "[bringup] first command after connecting: resize"
          echo >&2 "[bringup] tools: iostat -x 1 | mpstat -P ALL 1 | htop | zpool iostat -v 1 | strace -p <pid>"

          source ${bringupCommonScript}

          bootDiskImage=boot.raw
          ${preVmDiskImageVars}

          bringup::create_raw_disk "$bootDiskImage" ${toString bootDiskSize}
          ${preVmCreateRawDisks}
        '';

        postVM = ''
          mv "$bootDiskImage" "$out/boot.img"
          ${postVmMoveDiskImages}

          if [[ -f xchg/boot-size-hint.yaml ]]; then
            mv xchg/boot-size-hint.yaml "$out/boot-size-hint.yaml"
          fi

          set -x
          ${postVM}
        '';
      }
      ''
          set -x
          export PATH=${tools}:$PATH

          : 'shell.sock → /dev/hvc0 (first virtio-serial port we add).'
          : 'Use hvc0 directly — the /dev/virtio-ports/ symlink needs udev'
          : 'and may not exist yet; hvc0 is created by the kernel in devtmpfs.'
          : '-i: interactive (job control + prompt); skip -l to avoid /etc/profile.'
          while [[ ! -c /dev/hvc0 ]]; do sleep 0.1; done
          setsid --ctty ${pkgs.bash}/bin/bash -i 0<>/dev/hvc0 1>&0 2>&0 &

          : 'execute the ZFS bringup install script, which formats the disks and installs NixOS onto them'
          exec ${pkgs.bash}/bin/bash ${zfsBringupInstallScript}/bin/bringup-zfs-disk-images-install
      ''
  )
