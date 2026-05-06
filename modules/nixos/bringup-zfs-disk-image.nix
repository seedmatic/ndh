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
  # Bringup is I/O-bound (nix-store --load-db + nix copy → ZFS virtio-blk).
  # 4 vCPUs balances ZFS checksum/compression threads with nested hypervisor
  # overhead — max safe value for nested KVM on Apple Virtualization.framework.
  vmCpuCores ? 4,
  includeChannel ? false,

  qemuFallbackInVm ? null, # deprecated, no-op — accel detected at build time via /dev/kvm
  name ? "nixos-bringup-zfs-disk-images",
  # When false, the nested QEMU guest has no network at all.
  nestedQemuNetworkEnable ? true,
  postVM ? "",
  # Pre-computed disko configuration attrset — when provided, used directly to
  # generate the disko config file instead of re-evaluating zfs-disko-config.nix.
  diskoConfiguration ? null,
  # When set to a nixosDiskImages derivation (e.g. nerd-nixos), its tank/recover
  # disk images are copied into the build instead of creating blank disks.
  # disko format is skipped; existing ZFS pools are imported via disko mount.
  baseImagePath ? null,
  # When true, create a lock file in xchg/ after nixos-install completes.
  # The build pauses until the operator removes it, allowing inspection of
  # /mnt/zfs-root via the debug shell (socat → /proc/<qemu-pid>/shell.sock).
  # Remove with:  rm /tmp/xchg/pause.lock   (from inside the debug shell)
  pauseAfterInstall ? false,
}:
let
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

  tools = lib.makeBinPath (
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
    ++ initrdEmergencyPackages
  );

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
            baseImageMode = if baseImagePath != null then "1" else "0";
            pauseAfterInstall = if pauseAfterInstall then "1" else "0";
          }
        } "$out/bin/bringup-zfs-disk-images-install"
      '';

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
}).runInLinuxVM
  (
    pkgs.runCommand name
      {
        QEMU_OPTS = lib.concatStringsSep " " [
          "-drive file=$bootDiskImage,if=virtio,format=raw,cache=unsafe,aio=io_uring,werror=report"
          qemuAdditionalDriveOpts
          nestedQemuNetOpts
        ];
        NIX_BUILD_CORES = toString vmCpuCores;
        inherit memSize;

        # Allow the macOS caller to inject runtime-only knobs without breaking
        # the derivation's content-address.  Values are read from the nix-build
        # caller's environment (macOS side) and forwarded to the linux-builder
        # sandbox by the Nix protocol.
        impureEnvVars = [
          "NDH_BUILD_OBSERVE"
          "NDH_ZFS_INSTALL_OBSERVE"
          "NDH_ZFS_INSTALL_OBSERVE_INTERVAL"
          "NDH_BRINGUP_PAUSE"
          "NDH_VECTOR_ENDPOINT"
        ];

        preVM = ''
          PS4='[bringup-preVM:''${LINENO}] '
          set -x
          PATH="$PATH:${pkgs.qemu_kvm}/bin"
          mkdir "$out"

          # ── Vector relay ────────────────────────────────────────────────────
          # Nested QEMU uses SLIRP user-net: 10.0.2.2 = linux-builder, not macOS.
          # Relay: nested QEMU → linux-builder:PORT → macOS Vector (same PORT).
          # NDH_VECTOR_ENDPOINT injected via --impure-env; fallback to hardcoded default for testing.
          NDH_VECTOR_ENDPOINT="''${NDH_VECTOR_ENDPOINT:-http://10.0.2.2:9001}"
          _NDH_VECTOR_RELAY_PID=""
          if [[ -n "''${NDH_VECTOR_ENDPOINT:-}" ]]; then
            _ndh_relay_port="''${NDH_VECTOR_ENDPOINT##*:}"
            ${pkgs.socat}/bin/socat \
              TCP-LISTEN:"''${_ndh_relay_port}",fork,reuseaddr,bind=0.0.0.0 \
              TCP:10.0.2.2:"''${_ndh_relay_port}" &
            _NDH_VECTOR_RELAY_PID="$!"
          fi


          : 'Connect to debug shell (Ctrl+] to disconnect):'
          : '  sudo socat UNIX-CONNECT:/proc/$(pgrep --newest qemu)/shell.sock -,raw,echo=0,escape=0x1d'
          :
          : 'First thing after connecting — fix terminal size:'
          : '  resize'
          :
          : 'Perf / debug tools available in the shell:'
          : '  iostat -x 1              — per-disk utilisation, await, queue depth'
          : '  mpstat -P ALL 1          — per-CPU breakdown'
          : '  pidstat -d 1             — per-process I/O rates'
          : '  iotop-c                  — live top-style I/O monitor'
          : '  htop                     — CPU/mem/process overview'
          : '  vmstat 1                 — memory pressure + block I/O summary'
          : '  zpool iostat -v 1        — ZFS pool throughput'
          : '  lsof                     — open files, sockets, ZFS handles'
          : '  strace -p <pid>          — syscall trace on any process'

          QEMU_OPTS="$QEMU_OPTS -device virtio-serial -chardev socket,id=shell-sock,path=$PWD/shell.sock,server=on,wait=off -device virtconsole,chardev=shell-sock,name=shell"

          source ${./bringup-disk-image-common.sh}

          bootDiskImage=boot.raw
          ${preVmDiskImageVars}
          ${
            if baseImagePath != null then
              ''
                cp "${baseImagePath}/boot.img" "$bootDiskImage"
                ${lib.concatStringsSep "\n          " (
                  map (entry: "cp \"${baseImagePath}/${entry.disk}.img\" \"${entry.disk}DiskImage\"") zfsPoolDiskMap
                )}
                chmod +w "$bootDiskImage" ${lib.concatStringsSep " " (map (e: "\"${e.disk}DiskImage\"") zfsPoolDiskMap)}
              ''
            else
              ''
                bringup::create_raw_disk "$bootDiskImage" ${toString bootDiskSize}
                ${preVmCreateRawDisks}
              ''
          }
        '';

        postVM = ''
          mv "$bootDiskImage" "$out/boot.img"
          ${postVmMoveDiskImages}

          if [[ -f xchg/boot-size-hint.yaml ]]; then
            mv xchg/boot-size-hint.yaml "$out/boot-size-hint.yaml"
          fi

          if [[ -f xchg/zfs-nixos-install-observe.yaml ]]; then
            mv xchg/zfs-nixos-install-observe.yaml "$out/zfs-nixos-install-observe.yaml"
          fi

          if [[ -f xchg/builder-observe.yaml ]]; then
            mv xchg/builder-observe.yaml "$out/builder-observe.yaml"
          fi

          [[ -n "''${_NDH_VECTOR_RELAY_PID:-}" ]] && kill "''${_NDH_VECTOR_RELAY_PID}" 2>/dev/null || true

          PS4='[bringup-postVM:''${LINENO}] '
          set -x
          ${postVM}
        '';
      }
      ''
        PS4='[bringup-vm:''${LINENO}] '
        set -x
        export PATH=${tools}:$PATH

        : 'shell.sock → /dev/hvc0 (first virtio-serial port we add).'
        : 'Use hvc0 directly — the /dev/virtio-ports/ symlink needs udev'
        : 'and may not exist yet; hvc0 is created by the kernel in devtmpfs.'
        : '-i: interactive (job control + prompt); skip -l to avoid /etc/profile.'
        while [[ ! -c /dev/hvc0 ]]; do sleep 0.1; done
        setsid --ctty ${pkgs.bash}/bin/bash -i 0<>/dev/hvc0 1>&0 2>&0 &

        # ── builder-side observer ────────────────────────────────────────────
        # One background yq writer reads JSON lines from a named pipe and emits
        # a YAML stream to builder-observe.yaml (picked up by postVM → $out).
        # Samplers use yq heredocs to produce correct JSON — no manual escaping.
        _ndh_bld_obs_enabled() { [[ "''${NDH_ZFS_INSTALL_OBSERVE:-1}" == "1" ]]; }

        _ndh_bld_obs_sample() {
          local ts qemu_pid qemu_cpu qemu_rss dirty wb avail diskio
          ts=$(date -Iseconds)

          # QEMU process stats (CPU%, RSS in MB)
          qemu_pid=$(pgrep -n qemu 2>/dev/null || echo "")
          if [[ -n "$qemu_pid" ]]; then
            read -r qemu_cpu qemu_rss < <(
              ps -p "$qemu_pid" -o %cpu=,rss= 2>/dev/null \
                | awk '{printf "%s %d", $1, int($2/1024)}'
            )
          else
            qemu_cpu="0" qemu_rss="0"
          fi

          # Host memory pressure
          dirty=$(awk '$1=="Dirty:"        {print $2}' /proc/meminfo 2>/dev/null || echo 0)
          wb=$(awk    '$1=="Writeback:"    {print $2}' /proc/meminfo 2>/dev/null || echo 0)
          avail=$(awk '$1=="MemAvailable:" {print $2}' /proc/meminfo 2>/dev/null || echo 0)

          # Per-disk I/O on the build device (virtio or loop backing the .raw files)
          diskio=$(iostat -dxz 1 1 2>/dev/null \
            | awk 'NF>=16 && $1!~/Device|^$/{
                printf "{\"dev\":\"%s\",\"r_s\":%s,\"w_s\":%s,\"w_await_ms\":%s,\"util_pct\":%s},",
                  $1,$2,$3,$11,$NF
              }' \
            | sed 's/,$//' | awk '{print "["$0"]"}')
          [[ -n "$diskio" ]] || diskio="[]"

          yq -p yaml -o json -I0 - <<EOJ >&"''${_NDH_BLD_OBS_FD}" 2>/dev/null || true
type: builder-sample
source_layer: builder
ts: "''${ts}"
qemu:
  pid: "''${qemu_pid:-}"
  cpu_pct: ''${qemu_cpu:-0}
  rss_mb: ''${qemu_rss:-0}
mem:
  dirty_kb: ''${dirty}
  writeback_kb: ''${wb}
  avail_mb: $(( avail / 1024 ))
diskio: ''${diskio}
EOJ
        }

        _ndh_bld_obs_mark() {
          [[ -n "''${_NDH_BLD_OBS_FD:-}" ]] || return 0
          yq -p yaml -o json -I0 - <<EOJ >&"''${_NDH_BLD_OBS_FD}" 2>/dev/null || true
type: builder-phase
source_layer: builder
label: "''${1}"
ts: "$(date -Iseconds)"
EOJ
        }

        # Push a JSON event to Vector on the VZ host.
        # NDH_VECTOR_ENDPOINT injected via --impure-env; fallback to hardcoded default for testing.
        _ndh_bld_obs_push_vector() {
          local endpoint="''${NDH_VECTOR_ENDPOINT:-http://10.0.2.2:9001}"
          ${pkgs.curl}/bin/curl -sf -X POST "''${endpoint}" \
            -H "Content-Type: application/json" \
            -d "$1" 2>/dev/null || true
        }

        _ndh_bld_obs_start() {
          _ndh_bld_obs_enabled || return 0
          local interval="''${NDH_ZFS_INSTALL_OBSERVE_INTERVAL:-5}"
          local pipe out_file="/tmp/xchg/builder-observe.yaml"
          pipe="$(mktemp -d)/bld-obs.fifo"
          mkfifo "$pipe"
          _NDH_BLD_OBS_PIPE="$pipe"

          # Writer: one long-lived yq process, reads until EOF.
          # Also relays each event to Vector (VZ host) when NDH_VECTOR_ENDPOINT is set.
          ( while IFS= read -r line; do
              printf '%s\n' "$line" | yq -p json -o yaml
              printf -- '---\n'
              _ndh_bld_obs_push_vector "$line"
            done < "$pipe"
          ) >> "$out_file" &
          _NDH_BLD_OBS_WRITER_PID="$!"

          exec {_NDH_BLD_OBS_FD}>"$pipe"
          export _NDH_BLD_OBS_FD _NDH_BLD_OBS_WRITER_PID _NDH_BLD_OBS_PIPE

          # Send header
          printf '%s\n' '{"type":"builder-meta","started":"'"$(date -Iseconds)"'"}' \
            >&"$_NDH_BLD_OBS_FD" 2>/dev/null || true

          # Sampler loop
          ( while true; do _ndh_bld_obs_sample; sleep "$interval"; done ) &
          _NDH_BLD_OBS_SAMPLER_PID="$!"
          export _NDH_BLD_OBS_SAMPLER_PID
        }

        _ndh_bld_obs_stop() {
          _ndh_bld_obs_enabled || return 0
          [[ -n "''${_NDH_BLD_OBS_SAMPLER_PID:-}" ]] && \
            kill "''${_NDH_BLD_OBS_SAMPLER_PID}" 2>/dev/null || true
          _ndh_bld_obs_mark "builder-stop"
          [[ -n "''${_NDH_BLD_OBS_FD:-}" ]] && exec {_NDH_BLD_OBS_FD}>&-
          [[ -n "''${_NDH_BLD_OBS_WRITER_PID:-}" ]] && \
            wait "''${_NDH_BLD_OBS_WRITER_PID}" 2>/dev/null || true
          [[ -n "''${_NDH_BLD_OBS_PIPE:-}" ]] && rm -f "''${_NDH_BLD_OBS_PIPE}" || true
        }

        _ndh_bld_obs_start
        trap '_ndh_bld_obs_stop' EXIT
        _ndh_bld_obs_mark "qemu-start"

        : 'execute the ZFS bringup install script, which formats the disks and installs NixOS onto them'
        ${pkgs.bash}/bin/bash ${zfsBringupInstallScript}/bin/bringup-zfs-disk-images-install
        _ndh_bld_obs_mark "qemu-done"
      ''
  )
