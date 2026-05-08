{
  lib,
  pkgs,
  config,
  installSystemPath ? config.system.build.toplevel,
  # Production runtime system closure to include in the bringup image store.
  # zfs-nixos-install.service uses this as NDH_NIXOS_INSTALL_SYSTEM_PATH to
  # install the full system without network access at first boot.
  runtimeSystemPath ? null,
  zpoolDiskSize ? 3196, # 3GiB (temporary - minimal system still has large closure)
  # Dedicated EFI boot disk size — holds only systemd-boot + kernel + initrd.
  bootDiskSize ? 600, # 600MiB (512MiB ESP + GPT overhead)
  memSize ? 1536,
  # Bringup is I/O-bound (nix-store --load-db + nix copy → ZFS virtio-blk).
  # 4 vCPUs balances ZFS checksum/compression threads with nested hypervisor
  # overhead — max safe value for nested KVM on Apple Virtualization.framework.
  vmCpuCores ? 4,
  includeChannel ? false,

  qemuFallbackInVm ? null, # deprecated, no-op — accel detected at build time via /dev/kvm
  name ? "nixos-bringup-zfs-disk-images",
  # Short host name shown in PS4 log prefix (e.g. "nerd", "bioskop", "nikopol").
  # Defaults to name so callers that don't set it still get a useful label.
  hostLabel ? name,
  # When false, the nested QEMU guest has no network at all.
  nestedQemuNetworkEnable ? true,
  postVM ? "",
  # User-provided postVM commands (kept as parameter for future extensibility)
  # Pre-computed disko configuration attrset — when provided, used directly to
  # generate the disko config file instead of re-evaluating zfs-disko-config.nix.
  diskoConfiguration ? null,
  # When true, create a lock file in xchg/ after nixos-install completes.
  # The build pauses until the operator removes it, allowing inspection of
  # /mnt/zfs-root via the debug shell (socat → /proc/<qemu-pid>/shell.sock).
  # Remove with:  rm /tmp/xchg/pause.lock   (from inside the debug shell)
  pauseAfterInstall ? false,
  # When true, enable ZFS install observability (iostat, zpool monitoring).
  enableInstallObserve ? true,
  # Observability sample interval in seconds.
  installObserveInterval ? 5,
  # Cloud-init user-data file (for minimal bringup systems)
  cloudInitUserData ? null,
}:
let
  postVmUserCommands = postVM;  # Rename to avoid shadowing in derivation
  zfsPoolDiskMap = import ./zfs-pool-disk-map.nix;
  espStartMiB = 1;
  espSizeMiB = 512;
  zfsStartMiB = espStartMiB + espSizeMiB + 1;
  virtioDeviceNameAt = index: "vd${lib.substring index 1 "bcdefghijklmnopqrstuvwxyz"}";
  zfsDiskDeviceMap = lib.listToAttrs (
    lib.imap0 (index: entry: {
      name = entry.disk;
      value = "/dev/${virtioDeviceNameAt index}";
    }) zfsPoolDiskMap
  );
  zfsPoolDiskMapJson = builtins.toJSON zfsPoolDiskMap;
  zfsPoolDiskMapJsonFile = pkgs.writeText "zfs-pool-disk-map.json" zfsPoolDiskMapJson;
  diskoDisksAttrLines = lib.concatStringsSep "\n          " (
    map (entry: "${entry.disk} = \"${zfsDiskDeviceMap.${entry.disk}}\";") zfsPoolDiskMap
  );
  qemuAdditionalDriveOpts = lib.concatStringsSep " " (
    map (
      entry:
      "-drive file=${entry.disk}DiskImage,if=virtio,format=raw,cache=unsafe,aio=io_uring,werror=report"
    ) zfsPoolDiskMap
  );
  preVmDiskImageVars = lib.concatStringsSep "\n          " (
    map (entry: "${entry.disk}DiskImage=${entry.disk}.raw") zfsPoolDiskMap
  );
  preVmCreateRawDisks = lib.concatStringsSep "\n          " (
    map (
      entry: "bringup::create_raw_disk \"${entry.disk}DiskImage\" ${toString zpoolDiskSize}"
    ) zfsPoolDiskMap
  );
  postVmMoveDiskImages = lib.concatStringsSep "\n          " (
    map (entry: "mv \"${entry.disk}DiskImage\" \"$out/${entry.disk}.img\"") zfsPoolDiskMap
  );
  qemuBin = "${pkgs.qemu_kvm}/bin/qemu-system-aarch64";

  # Wrapper that detects /dev/kvm at build time and selects the right accelerator.
  # - On linux-builder (macOS NixOS builder): no /dev/kvm → accel=tcg (software)
  # - On nerd-nixos (Tart VM with nested virt): /dev/kvm present → accel=kvm:tcg
  # vmTools embeds customQemu verbatim into a shell script; any args it appends
  # become positional args ($@) to this wrapper.
  kvmDetectQemu = pkgs.writeShellScript "qemu-kvm-detect" ''
    if [ -e /dev/kvm ]; then
      accel="kvm:tcg"
    else
      accel="tcg"
    fi
    exec ${qemuBin} -machine virt,gic-version=max,accel=$accel -cpu max "$@"
  '';

  vmToolsBase = pkgs.vmTools.override {
    customQemu = "${kvmDetectQemu}";
  };

  # Basic slirp network — gives DHCP and internet access to the guest.
  # No SSH/monit port-forwards: use the serial console socket instead.
  nestedQemuNetOpts =
    if nestedQemuNetworkEnable then
      "-netdev user,id=ndhnet0 -device virtio-net-pci,netdev=ndhnet0"
    else
      "";

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
    rootPaths = [
      installSystemPath
    ]
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

  toolsPackages = with pkgs; [
    coreutils
    curl
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
    inotify-tools
  ] ++ initrdEmergencyPackages;

  tools = lib.makeBinPath toolsPackages;

  diskoConfigFile =
    if diskoConfiguration != null then
      # Serialize the pre-computed config into a disko NixOS module file.
      # Avoids a second evaluation of zfs-disko-config.nix with identical args.
      pkgs.writeText "bringup-zfs-disko.nix" (
        "{ lib, ... }:\n" + lib.generators.toPretty { } { disko.devices = diskoConfiguration.devices; }
      )
    else
      pkgs.writeText "bringup-zfs-disko.nix" ''
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
              boot = "/dev/vda";
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

  zfsBringupInstallScript =
    pkgs.runCommand "io.nxmatic.nix-darwin-home-bringup-zfs-disk-images-install" { }
      ''
        install -Dm755 ${
          pkgs.replaceVars ./zfs.d/bringup-zfs-disk-images-install.sh {
            nixosName = hostLabel;
            bringupCommonScript = "${./bringup-disk-image-common.sh}";
            diskoFormatExe = "${diskoFormatExe}";
            diskoMountExe = "${diskoMountExe}";
            diskoUnmountExe = "${diskoUnmountExe}";
            closureRegistration = "${closureInfo}/registration";
            nixosInstall = "${config.system.build.nixos-install}/bin/nixos-install";
            systemToplevel = "${installSystemPath}";
            systemdLibUdevd = "${pkgs.systemd}/lib/systemd/systemd-udevd";
            channelFlag = if includeChannel then "--channel ${channelSources}" else "";
            bootSizePolicyNote = builtins.toJSON "ZFS bringup artifacts generated from canonical zfs-pool-disk-map definitions.";
            pauseAfterInstall = if pauseAfterInstall then "true" else "false";
            cloudInitUserData = if cloudInitUserData != null then "${cloudInitUserData}" else "";
          }
        } "$out/bin/bringup-zfs-disk-images-install"
      '';

  # buildCommandScript runs inside the VM
  buildCommandScriptApp = pkgs.writeShellApplication {
    name = "bringup-zfs-buildcommand";
    runtimeInputs = toolsPackages;
    # Read the buildcommand.sh source and inline it here
    text = ''
      export NDH_NIXOS_NAME="${hostLabel}"
      export NDH_ZFS_INSTALL_OBSERVE="${if enableInstallObserve then "true" else "false"}"
      export NDH_ZFS_INSTALL_OBSERVE_INTERVAL="${toString installObserveInterval}"
      export NDH_INSTALL_SCRIPT="${zfsBringupInstallScript}/bin/bringup-zfs-disk-images-install"

      ${builtins.readFile ./bringup-zfs-disk-image.d/buildcommand.sh}
    '';
  };
  buildCommandScript = lib.getExe buildCommandScriptApp;

in
(vmToolsBase.override {
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
}).runInLinuxVM (
  pkgs.runCommand name {
    QEMU_OPTS = lib.concatStringsSep " " [
      "-drive file=$bootDiskImage,if=virtio,format=raw,cache=unsafe,aio=io_uring,werror=report"
      qemuAdditionalDriveOpts
      nestedQemuNetOpts
    ];
    NIX_BUILD_CORES = toString vmCpuCores;
    inherit memSize;

    preVM = ''
      export NDH_NIXOS_NAME="${hostLabel}"
      export NDH_BRINGUP_COMMON_SCRIPT="${./bringup-disk-image-common.sh}"
      export NDH_BOOT_DISK_SIZE="${toString bootDiskSize}"
      export PATH="${lib.makeBinPath [ pkgs.socat pkgs.qemu_kvm ]}:$PATH"

      # Set up disk image variables
      bootDiskImage=boot.raw
      ${preVmDiskImageVars}

      # shellcheck disable=SC1090,SC1091
      source "${./bringup-disk-image-common.sh}"

      # Create fresh blank disk images
      bringup::create_raw_disk "$bootDiskImage" "${toString bootDiskSize}"
      ${preVmCreateRawDisks}

      # Export disk image variables so prevm.sh can reference them
      export bootDiskImage
      ${lib.concatStringsSep "\n      " (map (entry: "export ${entry.disk}DiskImage") zfsPoolDiskMap)}

      # Run the main preVM script (it will use the exported variables and set up QEMU_OPTS)
      # shellcheck disable=SC1090,SC1091
      source ${./bringup-zfs-disk-image.d/prevm.sh}
    '';

    postVM = ''
      export NDH_NIXOS_NAME="${hostLabel}"

      # Move disk images to $out
      mv "$bootDiskImage" "$out/boot.img"
      ${postVmMoveDiskImages}

      if [[ -f xchg/boot-size-hint.yaml ]]; then
        mv xchg/boot-size-hint.yaml "$out/boot-size-hint.yaml"
      fi

      [[ -n "''${_NDH_VECTOR_RELAY_PID:-}" ]] && kill "''${_NDH_VECTOR_RELAY_PID}" 2>/dev/null || true

      # User-provided postVM commands
      ${postVmUserCommands}
    '';
  } ''
    source ${buildCommandScript}
  ''
)
