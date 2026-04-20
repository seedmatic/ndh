# @codebase
# Build canonical ZFS bringup disk-set artifacts (tank1/tank2/tank3/recover).
{
  lib,
  pkgs,
  config,
  installSystemPath ? config.system.build.toplevel,
  zpoolDiskSize ? 1536, # 1.5GiB
  # Dedicated EFI boot disk size — holds only systemd-boot + kernel + initrd.
  bootDiskSize ? 600, # 600MiB (512MiB ESP + GPT overhead)
  memSize ? 1536,
  vmCpuCores ? 4,
  includeChannel ? false,
  useQemuImg ? false,
  qemuFallbackInVm ? true,
  name ? "nixos-bringup-zfs-disk-images",
  # When false, the nested QEMU guest has no network at all.
  nestedQemuNetworkEnable ? true,
  postVM ? "",
}:
let
  espStartMiB = 1;
  espSizeMiB = 512;
  zfsStartMiB = espStartMiB + espSizeMiB + 1;
  bringupCommon = import ./bringup-disk-image-common.nix {
    inherit
      lib
      pkgs
      qemuFallbackInVm
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
    rootPaths = [ installSystemPath ] ++ (lib.optional includeChannel channelSources);
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

  tools = lib.makeBinPath (
    with pkgs;
    [
      coreutils
      disko
      jq
      yq-go
      nixos-enter
      config.system.build.nixos-install
      dosfstools
      gptfdisk
      nix
      parted
      shadow
      systemd
      util-linux
      zfs
    ]
  );

  diskoConfigFile = pkgs.writeText "bringup-zfs-disko.nix" ''
    { lib, ... }:
    let
      cfg = import ${./zfs-disko-config.nix} {
        inherit lib;
        installRootMountPoint = "/mnt/zfs-root";
        diskImageSize = "${toString zpoolDiskSize}M";
        bootDiskImageSize = "${toString bootDiskSize}M";
        espStartMiB = ${toString espStartMiB};
        espSizeMiB = ${toString espSizeMiB};
        zfsStartMiB = ${toString zfsStartMiB};
        disks = {
          nixos = "/dev/vda";
          tank1 = "/dev/vdb";
          tank2 = "/dev/vdc";
          tank3 = "/dev/vdd";
          recover = "/dev/vde";
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

  zfsBringupInstallScript = pkgs.replaceVars ./zfs.d/bringup-zfs-disk-images-install.sh {
    bringupCommonScript = "${bringupCommonScript}";
    diskoFormatExe = "${diskoFormatExe}";
    diskoMountExe = "${diskoMountExe}";
    diskoUnmountExe = "${diskoUnmountExe}";
    closureRegistration = "${closureInfo}/registration";
    nixosInstall = "${config.system.build.nixos-install}/bin/nixos-install";
    systemToplevel = "${installSystemPath}";
    systemdLibUdevd = "${pkgs.systemd}/lib/systemd/systemd-udevd";
    channelFlag = if includeChannel then "--channel ${channelSources}" else "";
    bootSizePolicyNote = builtins.toJSON "ZFS bringup artifacts generated as tank1/tank2/tank3/recover images.";
  };

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
    "virtiofs"
  ];
  kernel = modulesTree;
}).runInLinuxVM
  (
    pkgs.runCommand name
      {
        QEMU_OPTS = lib.concatStringsSep " " [
          "-drive file=$bootDiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          "-drive file=$tank1DiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          "-drive file=$tank2DiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          "-drive file=$tank3DiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          "-drive file=$recoverDiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          nestedQemuNetOpts
        ];
        NIX_BUILD_CORES = toString vmCpuCores;
        inherit memSize;

        preVM = ''
          PATH="$PATH:${pkgs.qemu_kvm}/bin"
          mkdir "$out"

          # Expose the nested guest's serial console via a Unix-domain socket so
          # the build can be introspected from linux-builder even in emergency mode.
          # Connect (Ctrl+] to disconnect):
          #   qpid=$(pgrep -f "qemu-system.*nixos-disk-image-bringup" | head -1)
          #   sudo socat UNIX-CONNECT:/proc/$qpid/root/build/console.sock -,raw,echo=0,icanon=0,escape=0x1d
          QEMU_OPTS="$QEMU_OPTS -chardev socket,id=console-sock,path=$PWD/console.sock,server=on,wait=off -serial chardev:console-sock"
          echo "[bringup-image] debug shell on ttyS1 — connect: sudo socat UNIX-CONNECT:/proc/\$qpid/root/build/console.sock -,raw,echo=0,icanon=0,escape=0x1d  (Ctrl+] to disconnect)" >&2

          source ${bringupCommonScript}

          bootDiskImage=boot.raw
          tank1DiskImage=tank1.raw
          tank2DiskImage=tank2.raw
          tank3DiskImage=tank3.raw
          recoverDiskImage=recover.raw

          bringup::create_raw_disk "$bootDiskImage" ${toString bootDiskSize} ${
            if useQemuImg then "true" else "false"
          }
          bringup::create_raw_disk "$tank1DiskImage" ${toString zpoolDiskSize} ${
            if useQemuImg then "true" else "false"
          }
          bringup::create_raw_disk "$tank2DiskImage" ${toString zpoolDiskSize} ${
            if useQemuImg then "true" else "false"
          }
          bringup::create_raw_disk "$tank3DiskImage" ${toString zpoolDiskSize} ${
            if useQemuImg then "true" else "false"
          }
          bringup::create_raw_disk "$recoverDiskImage" ${toString zpoolDiskSize} ${
            if useQemuImg then "true" else "false"
          }
        '';

        postVM = ''
          mv "$bootDiskImage" "$out/boot.img"
          mv "$tank1DiskImage" "$out/tank1.img"
          mv "$tank2DiskImage" "$out/tank2.img"
          mv "$tank3DiskImage" "$out/tank3.img"
          mv "$recoverDiskImage" "$out/recover.img"

          if [[ -f boot-size-hint.yaml ]]; then
            mv boot-size-hint.yaml "$out/boot-size-hint.yaml"
          fi

          set -x
          ${postVM}
        '';
      }
      ''
        # Redirect this script's stdout/stderr to ttyS1 (host build log).
        # ttyS0 (console.sock socket) becomes the clean interactive shell channel.
        exec 1>/dev/ttyS1 2>&1

        export PATH=${tools}:$PATH
        set -x

        source ${bringupCommonScript}
        bringup::link_legacy_block_devices

        # Root shell on ttyS0 (console.sock) — clean channel, no install noise.
        # Connect from linux-builder (Ctrl+] to disconnect):
        #   qpid=$(pgrep -f "qemu-system.*nixos-disk-image-bringup" | head -1)
        #   sudo socat UNIX-CONNECT:/proc/$qpid/root/build/console.sock -,raw,echo=0,icanon=0,escape=0x1d
        setsid ${pkgs.bash}/bin/bash --login <>/dev/ttyS0 >&0 2>&1 &

        ${pkgs.bash}/bin/bash ${zfsBringupInstallScript}
      ''
  )
