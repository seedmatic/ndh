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

  # Packages for the bringup shell PATH. The forensic/disk tools are sourced from
  # the shared initrd-emergency-tools.nix to stay in sync with what the initrd
  # emergency shell provides at runtime.
  initrdEmergencyTools = import ./initrd-emergency-tools.nix pkgs;
  initrdEmergencyPackages = lib.unique (
    map (p: builtins.dirOf (builtins.dirOf p)) (builtins.attrValues initrdEmergencyTools)
  );

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
          "-drive file=$tank1DiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          "-drive file=$tank2DiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          "-drive file=$tank3DiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          "-drive file=$recoverDiskImage,if=virtio,format=raw,cache=unsafe,werror=report"
          nestedQemuNetOpts
        ];
        NIX_BUILD_CORES = toString vmCpuCores;
        inherit memSize;

        preVM = ''
          set -x
          PATH="$PATH:${pkgs.qemu_kvm}/bin"
          mkdir "$out"

          # shell.sock: dedicated interactive root shell via virtio-serial (hvc0).
          # The nix build log receives all VM output naturally via -nographic stdio (ttyAMA0).
          # Do NOT add -serial here — it would steal ttyAMA0 from stdio, silencing the build log.
          #
          # Connect to debug shell (Ctrl+] to disconnect):
          #   qpid=$(pgrep --newest qemu)
          #   sudo socat UNIX-CONNECT:/proc/$qpid/root/build/shell.sock -,raw,echo=0,escape=0x1d
          #
          # First thing after connecting — fix terminal size:
          #   resize
          #
          # Perf / debug tools available in the shell:
          #   iostat -x 1              — per-disk utilisation, await, queue depth
          #   mpstat -P ALL 1          — per-CPU breakdown
          #   pidstat -d 1             — per-process I/O rates
          #   iotop-c                  — live top-style I/O monitor
          #   htop                     — CPU/mem/process overview
          #   vmstat 1                 — memory pressure + block I/O summary
          #   zpool iostat -v 1        — ZFS pool throughput
          #   lsof                     — open files, sockets, ZFS handles
          #   strace -p <pid>          — syscall trace on any process
          QEMU_OPTS="$QEMU_OPTS -device virtio-serial -chardev socket,id=shell-sock,path=$PWD/shell.sock,server=on,wait=off -device virtconsole,chardev=shell-sock,name=shell"

          source ${bringupCommonScript}

          bootDiskImage=boot.raw
          tank1DiskImage=tank1.raw
          tank2DiskImage=tank2.raw
          tank3DiskImage=tank3.raw
          recoverDiskImage=recover.raw

          bringup::create_raw_disk "$bootDiskImage" ${toString bootDiskSize}
          bringup::create_raw_disk "$tank1DiskImage" ${toString zpoolDiskSize}
          bringup::create_raw_disk "$tank2DiskImage" ${toString zpoolDiskSize}
          bringup::create_raw_disk "$tank3DiskImage" ${toString zpoolDiskSize}
          bringup::create_raw_disk "$recoverDiskImage" ${toString zpoolDiskSize}

          : 'qemu pid: qpid=$(pgrep --newest qemu)'
          : 'build log (Ctrl+] to exit): sudo socat UNIX-CONNECT:/proc/$qpid/root/build/console.sock -,raw,echo=0,escape=0x1d'
          : 'debug shell (Ctrl+] to exit): sudo socat UNIX-CONNECT:/proc/$qpid/root/build/shell.sock -,raw,echo=0,escape=0x1d'
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
          set -x
          export PATH=${tools}:$PATH

          : 'shell.sock → /dev/hvc0 (first virtio-serial port we add).'
          : 'Use hvc0 directly — the /dev/virtio-ports/ symlink needs udev'
          : 'and may not exist yet; hvc0 is created by the kernel in devtmpfs.'
          : '-i: interactive (job control + prompt); skip -l to avoid /etc/profile.'
          while [[ ! -c /dev/hvc0 ]]; do sleep 0.1; done
          setsid --ctty ${pkgs.bash}/bin/bash -i 0<>/dev/hvc0 1>&0 2>&0 &

          : 'execute the ZFS bringup install script, which formats the disks and installs NixOS onto them'
          exec ${pkgs.bash}/bin/bash ${zfsBringupInstallScript}
      ''
  )
