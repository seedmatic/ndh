{
  lib,
  pkgs,
  config,
  # Path to nix-bash-trampoline.sh, forwarded to the layer packer so its asset
  # script bootstraps through the same bash + logger as the rest of the tree.
  nixBashTrampoline,
  installSystemPath ? config.system.build.toplevel,
  # Production runtime system closure, packed as its own EROFS layer so the node
  # mounts it instead of materializing it: `nixos-rebuild` otherwise creates
  # 165 591 files in the overlay upper, outside any derivation.  Required —
  # erofs-store-layers.nix declares a layer for it, and a declared layer with no
  # content is a disk the guest must mount to boot and that holds nothing.
  runtimeSystemPath,
  zpoolDiskSize ? 3196, # 3GiB (temporary - minimal system still has large closure)
  # Dedicated EFI boot disk size — holds only systemd-boot + kernel + initrd.
  bootDiskSize ? (import ./zfs-partition-layout.nix).bootDiskSizeMiB,
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
  # When true, enable build observability (nested VM sampler + event emission).
  enableBuildObserve ? false,
  # Observability sample interval in seconds (shared across all source layers).
  buildObserveInterval ? 5,
}:
let
  postVmUserCommands = postVM; # Rename to avoid shadowing in derivation
  partLayout = import ./zfs-partition-layout.nix;
  storeLayers = import ./erofs-store-layers.nix;
  zfsPoolDiskMap = import ./zfs-pool-disk-map.nix;
  espStartMiB = partLayout.espStartMiB;
  espSizeMiB = partLayout.espSizeMiB;
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

  # vmTools invokes virtiofsd twice with hardcoded flags (store + xchg shares)
  # and exposes no hook for extra options.  Wrap the `virtiofsd` input so the
  # STORE share gets `--cache=always`: the nix store is immutable during the
  # build, so aggressive metadata/data caching in the guest collapses the
  # per-file virtiofs round-trips that otherwise cap the image build at a few
  # MB/s (measured: store served at ~1-2 MB/s, guest CPU pinned in %system,
  # disk idle — the bottleneck is virtiofs lookup latency, not I/O).  The xchg
  # share is read-write from both host and guest (boot-size-hint / pause.lock
  # handoff), so it must keep the default `auto` coherence — discriminated by
  # its socket path.
  virtiofsdStoreCached = pkgs.writeShellScriptBin "virtiofsd" ''
    case " $* " in
      *" --socket-path virtio-store.sock "*)
        exec ${pkgs.virtiofsd}/bin/virtiofsd --cache=always "$@" ;;
      *)
        exec ${pkgs.virtiofsd}/bin/virtiofsd "$@" ;;
    esac
  '';

  vmToolsBase = pkgs.vmTools.override {
    customQemu = "${kvmDetectQemu}";
    virtiofsd = virtiofsdStoreCached;
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

  # Base layer: the bringup closure ALONE.  Keeping the runtime out of here is
  # what makes a second layer possible at all — nix records a reference for every
  # store path it finds in an output, so letting the bringup toplevel name the
  # runtime toplevel (as ndh.context.runtimeSystemPath does, via the install
  # service's environment) would pull the entire runtime closure into this set
  # and flatten the stack back to one layer.  That is precisely why
  # runtimeSystemPath was left null here before the stack existed.
  baseClosureInfo = pkgs.closureInfo {
    rootPaths = [ installSystemPath ] ++ (lib.optional includeChannel channelSources);
  };

  runtimeClosureInfo = pkgs.closureInfo { rootPaths = [ runtimeSystemPath ]; };

  # What the installer replays into the target Nix database.  It must describe
  # the UNION of the stack, not any single layer: a layer's path set is not
  # dependency-closed on its own (measured: 142 outbound references over 60
  # sampled delta paths), so registering per layer would declare paths whose
  # references are missing and nix would conclude it must re-copy the closure
  # into the overlay upper.
  unionClosureInfo = pkgs.closureInfo {
    rootPaths = [
      installSystemPath
      runtimeSystemPath
    ]
    ++ (lib.optional includeChannel channelSources);
  };

  # The runtime layer carries what the base does not already hold — a set
  # difference, for the reasons erofs-store-image.d/delta.sh states.
  storeLayerDeltaScript = pkgs.replaceVars ./erofs-store-image.d/delta.sh {
    inherit nixBashTrampoline;
    loggerTag = "nixos.erofsStoreLayerDelta";
  };

  runtimeDeltaStorePaths =
    pkgs.runCommand "io.seedmatic.ndh-nix-store-erofs-runtime-delta-paths" { }
      ''
        ${pkgs.bash}/bin/bash ${storeLayerDeltaScript} \
          ${baseClosureInfo}/store-paths \
          ${runtimeClosureInfo}/store-paths \
          "$out"
      '';

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

  toolsPackages =
    with pkgs;
    [
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
    ]
    ++ initrdEmergencyPackages;

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

  zfsBringupInstallScript = pkgs.runCommand "io.seedmatic.ndh-bringup-zfs-disk-images-install" { } ''
    install -Dm755 ${
      pkgs.replaceVars ./zfs.d/bringup-zfs-disk-images-install.sh {
        inherit nixBashTrampoline;
        loggerTag = "nixos.bringupZfsDiskImagesInstall";
        nixosName = hostLabel;
        bringupCommonScript = "${./bringup-disk-image-common.sh}";
        diskoFormatExe = "${diskoFormatExe}";
        diskoMountExe = "${diskoMountExe}";
        diskoUnmountExe = "${diskoUnmountExe}";
        closureRegistration = "${unionClosureInfo}/registration";
        nixosInstall = "${config.system.build.nixos-install}/bin/nixos-install";
        systemToplevel = "${installSystemPath}";
        systemdLibUdevd = "${pkgs.systemd}/lib/systemd/systemd-udevd";
        channelFlag = if includeChannel then "--channel ${channelSources}" else "";
        bootSizePolicyNote = builtins.toJSON "ZFS bringup artifacts generated from canonical zfs-pool-disk-map definitions.";
        pauseAfterInstall = if pauseAfterInstall then "true" else "false";
        inherit storeLayerMountSpecs storeLayerRoMountPoints storeLayerGcrootSpecs;
        storeRwMountPoint = storeLayers.rwMountPoint;
        storeMountPoint = storeLayers.storeMountPoint;
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
      export NDH_BUILD_OBSERVE="${if enableBuildObserve then "true" else "false"}"
      export NDH_BUILD_OBSERVE_INTERVAL="${toString buildObserveInterval}"
      export NDH_INSTALL_SCRIPT="${zfsBringupInstallScript}/bin/bringup-zfs-disk-images-install"
      # bashInteractive carries readline (history + line editing); the default
      # `bash` in writeShellApplication's PATH is the minimal non-interactive
      # build. buildcommand.sh uses this path for the /dev/hvc0 debug shell.
      export NDH_INTERACTIVE_BASH="${pkgs.bashInteractive}/bin/bash"

      ${builtins.readFile ./bringup-zfs-disk-image.d/buildcommand.sh}
    '';
  };
  buildCommandScript = lib.getExe buildCommandScriptApp;

  # What each declared layer carries.  erofs-store-layers.nix names the layers;
  # the closure they hold is a build-time decision, so it is bound here.
  #
  # `rootPath` is what the layer's GC root points at — the toplevel whose closure
  # the layer was packed from.  Without it a layer is rooted only by whichever
  # system profile generation still names it, which is exactly what
  # `nix-collect-garbage -d` prunes.
  storeLayerContent = {
    store = {
      storePathsFile = "${baseClosureInfo}/store-paths";
      rootPath = installSystemPath;
    };
    store-002 = {
      storePathsFile = "${runtimeDeltaStorePaths}";
      rootPath = runtimeSystemPath;
    };
  };

  storeLayerBindings = map (layer: layer // storeLayerContent.${layer.imageName}) storeLayers.layers;

  # Read-only layers of the produced image's /nix/store, packed HERE on the host
  # rather than materialized file-by-file inside the nested guest.  Each takes
  # the union `closureInfo` so its `passthru` describes the stack it belongs to,
  # while `storePathsFile` selects the subset it actually packs.
  storeImages = lib.listToAttrs (
    map (binding: {
      name = binding.imageName;
      value = import ./erofs-store-image.nix {
        inherit pkgs lib nixBashTrampoline;
        closureInfo = unionClosureInfo;
        inherit (binding) label uuid storePathsFile;
        # Distinct per layer, so a store path says which layer it is instead of
        # leaving two identically-named images to tell apart by hash.
        name = "io.seedmatic.ndh-nix-store-erofs-${binding.name}";
      };
    }) storeLayerBindings
  );

  # Descriptive projection of the stack, merged into the VM manifest so a disk set
  # is legible without reading erofs-store-layers.nix.  Deliberately NOT folded
  # into each image's `role`: that field is a delivery contract the darwin
  # activation branches on (`role == prebuilt` => copy verbatim, never resize,
  # never probe for ZFS), so overloading it would mix two concerns.  Kept as an
  # ordered list because the stack IS ordered — per-image entries would lose that.
  storeLayersSpec = map (binding: {
    index = binding.name;
    image = binding.imageName;
    inherit (binding) label purpose;
    mountPoint = binding.roMountPoint;
    rootPath = "${binding.rootPath}";
  }) storeLayerBindings;

  # Projections of the stack onto the shape each consumer needs.  The shell specs
  # are quoted here rather than at expansion time: replaceVars substitutes into
  # the script text, so the quotes land in the file and bash parses each spec as
  # one word.
  storeLayerMountSpecs = lib.concatStringsSep " " (
    map (layer: "'${layer.label}:${layer.roMountPoint}'") storeLayers.layers
  );
  # Unmount order is the reverse of the mount order.
  storeLayerRoMountPoints = lib.concatStringsSep " " (
    map (layer: "'${layer.roMountPoint}'") (lib.reverseList storeLayers.layers)
  );
  storeLayerGcrootSpecs = lib.concatStringsSep " " (
    map (binding: "'${binding.name}:${binding.rootPath}'") storeLayerBindings
  );

  # Attached after the pool disks so those keep their vdb…vde ordering
  # (zfsDiskDeviceMap indexes from vdb).  `if=virtio` on purpose — an explicit
  # `-device` for these breaks the guest's boot.
  qemuStoreLayerDriveOpts = lib.concatStringsSep " " (
    map (
      binding: "-drive file=${storeImages.${binding.imageName}},if=virtio,format=raw,readonly=on"
    ) storeLayerBindings
  );

  diskImages =
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
        # Needed to mount the prebuilt store lower + its writable overlay onto
        # the target root before nixos-install runs.
        "erofs"
        "overlay"
      ];
      kernel = modulesTree;
    }).runInLinuxVM
  (
    pkgs.runCommand name
      {
        QEMU_OPTS = lib.concatStringsSep " " [
          "-drive file=$bootDiskImage,if=virtio,format=raw,cache=unsafe,aio=io_uring,werror=report"
          qemuAdditionalDriveOpts
          # Prebuilt store layers, attached last.  The installer mounts them as
          # the target's stack instead of unpacking the closure into the pool.
          qemuStoreLayerDriveOpts
          nestedQemuNetOpts
        ];
        NIX_BUILD_CORES = toString vmCpuCores;
        inherit memSize;

        preVM = ''
          export NDH_NIXOS_NAME="${hostLabel}"
          export NDH_BRINGUP_COMMON_SCRIPT="${./bringup-disk-image-common.sh}"
          export NDH_BOOT_DISK_SIZE="${toString bootDiskSize}"
          export PATH="${
            lib.makeBinPath [
              pkgs.socat
              pkgs.qemu_kvm
            ]
          }:$PATH"

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
      }
      ''
        source ${buildCommandScript}
      ''
  );
in
{
  inherit diskImages storeImages storeLayersSpec;
}
