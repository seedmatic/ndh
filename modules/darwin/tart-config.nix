# Tart raw->ASIF image materialization (@codebase)
# Generates stable gcroot links for raw and ASIF images used by Tart workflows.

{
  config,
  pkgs,
  lib,
  catalog,
  inventory,
  ndh,
  ...
}:

let
  inherit (lib) mkOption types;
  ndhContext = ndh.context;
  nixBashTrampoline = "${ndhContext.nixBashTrampoline}";

  profileUser = config.profile.user.name;
  profileHome = config.profile.user.home;
  profileHost = config.profile.host;

  effectiveHostName =
    if (profileHost ? hostAlias && profileHost.hostAlias != null && profileHost.hostAlias != "") then
      profileHost.hostAlias
    else
      profileHost.hostName;

  # Keep Tart LAN MAC aligned with Lima LAN interface derivation for the same host.
  hostByteHex =
    let
      hash = builtins.hashString "sha256" effectiveHostName;
    in
    lib.strings.toLower (builtins.substring 0 2 hash);

  hostInventoryEntries =
    lib.attrByPath
      [
        "hosts"
        effectiveHostName
      ]
      [ ]
      inventory;

  tartRuntimeSupported = lib.any (
    entry: (entry ? vm) && (entry.vm ? manager) && entry.vm.manager == "tart"
  ) hostInventoryEntries;
  selectedVmProvider =
    if profileHost ? vmProvider && profileHost.vmProvider != null then
      profileHost.vmProvider
    else
      "lima";
  tartProviderSelected = selectedVmProvider == "tart";
  tartMaterializationEnabled = tartProviderSelected && (tartRuntimeSupported || cfg.forceEnable);

  cfg = config.tart.configGenerator;
  tartPackageAvailable = pkgs ? tart;

  rawImageManifestPath =
    if cfg.rawImageManifestPath == null then "" else toString cfg.rawImageManifestPath;
  rawImageStorePath = if cfg.rawImageStorePath == null then "" else toString cfg.rawImageStorePath;

  # Directory in the bringup images store that contains manifest.yaml + *.img files.
  # Prefer rawImageManifestPath's parent; fall back to rawImageStorePath's parent.
  bringupImagesDir =
    if rawImageManifestPath != "" then
      builtins.dirOf rawImageManifestPath
    else if rawImageStorePath != "" then
      builtins.dirOf rawImageStorePath
    else
      "";

  # Bundle directory: bin/activate.sh + bringup-manifest → bringup images store dir.
  # The gcroot points here so one symlink keeps the entire disk-image closure alive.
  # manifest.yaml is linked here too so run.sh can resolve it via the stable gcroot path.
  # runtime-system is a closure-only symlink (activation never dereferences it)
  # that pulls the full NixOS runtime system into the bundle's closure so a
  # single `nix build` stages both the bringup image and the target system the
  # operator will activate remotely.  Build hosts pass includeRuntimeClosure=true
  # to materialize the convenience symlink; deploy hosts (vz hosts that only
  # consume artifacts) pass false to keep the closure to disk-image references
  # only — saving ~16 GiB and ~1800 store paths.
  # `embedManifest`: when true, the bundle includes a manifest.yaml symlink
  # and bakes its store path into activate.sh's @manifestPath@ default.  Used
  # by the per-host materializer (so darwin-rebuild's postActivation hook can
  # invoke activate.sh without --config).  The generic nerd-tart deploy
  # bundle passes false: it ships activate.sh with @manifestPath@ = "", and
  # the operator selects a VM identity via --config FILE at runtime.
  #
  # `includeRuntimeClosure`: when true, adds a runtime-system symlink that
  # pulls the full target NixOS closure into the bundle.  Build hosts pass
  # true so a single `nix build` stages both image and runtime system; the
  # generic deploy bundle passes false.
  #
  # `includeBringupSymlink`: when true, adds a bringup-manifest symlink that
  # pulls the bringup disk images (~15 GiB of raw bytes scanned as store refs)
  # into the bundle's closure.  Build hosts pass true so darwin-rebuild's
  # postActivation hook can resolve the images locally.  The generic deploy
  # bundle passes false: the operator nix-copies `nixosDiskImages.nerd`
  # separately and wires the resolved store path via the per-VM YAML's
  # `raw_image_manifest_path_default` field.
  mkActivationBundle =
    {
      drvName,
      embedManifest,
      includeRuntimeClosure,
      includeBringupSymlink,
    }:
    ndh.store.runCommand drvName { } ''
      mkdir -p "$out/bin"
      cp ${
        pkgs.replaceVars ./tart-config.d/activation.sh {
          nixBashTrampoline = nixBashTrampoline;
          manifestPath = if embedManifest then toString tartRunManifest else "";
          tartRunScript = tartRunScript;
          tartActivationBundlePlaceholder = "PLACEHOLDER";
        }
      } "$out/bin/activate.sh"
      # Patch the self-referential placeholder with the real output store path.
      # replaceVars cannot self-reference $out, so we substitute after the copy.
      sed -i "s|PLACEHOLDER|$out|g" "$out/bin/activate.sh"
      chmod +x "$out/bin/activate.sh"
      ${lib.optionalString embedManifest ''
        ln -s ${lib.escapeShellArg (toString tartRunManifest)} "$out/manifest.yaml"
      ''}
      ${lib.optionalString (includeBringupSymlink && bringupImagesDir != "") ''
        ln -s ${lib.escapeShellArg bringupImagesDir} "$out/bringup-manifest"
      ''}
      ${lib.optionalString (includeRuntimeClosure && cfg.runtimeSystemPath != null) ''
        ln -s ${lib.escapeShellArg (toString cfg.runtimeSystemPath)} "$out/runtime-system"
      ''}
    '';

  tartActivationBundle = mkActivationBundle {
    drvName = "tart-${cfg.vmName}-materialize";
    embedManifest = true;
    includeRuntimeClosure = true;
    includeBringupSymlink = true;
  };

  # Generic, host-agnostic deploy bundle.  No baked-in run manifest, no
  # runtime-system closure, no bringup symlink — closure is bounded by the
  # activate/run scripts and their PATH dependencies (~50-100 MiB).  The
  # operator selects a VM identity at runtime by passing --config FILE to
  # activate.sh, where FILE is a per-VM YAML produced by the matching
  # `nerd-tart-<host>-config` flake package and placed under
  # $XDG_CONFIG_HOME/nerd-tart/<vm>.yaml on the vz host.  The bringup
  # disk images travel as a separate `nix copy` of `nixosDiskImages.nerd`,
  # and the per-VM YAML carries their resolved store path.
  tartDeployBundle = mkActivationBundle {
    drvName = "nerd-tart-deploy";
    embedManifest = false;
    includeRuntimeClosure = false;
    includeBringupSymlink = false;
  };

  # Convenience alias: the activation script file inside the bundle.
  tartActivationScript = "${tartActivationBundle}/bin/activate.sh";
  tartDeployActivationScript = "${tartDeployBundle}/bin/activate.sh";

  tartMaterializerPackage = pkgs.writeShellScriptBin "nerd-tart-vm-materialize" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.openssh
        pkgs.gawk
        pkgs.gnused
        pkgs.coreutils
        pkgs.findutils
        pkgs.procps
        pkgs.yq-go
        pkgs.util-linux
        pkgs.bash
      ]
    }:/usr/bin:/bin:/usr/sbin:/sbin"

    if ''${NDH_LINUX_BUILDER_GC_BEFORE_BUILD:-${
      if cfg.linuxBuilderGcBeforeBuild then "true" else "false"
    }}; then
      builder_target="''${NDH_LINUX_BUILDER_GC_TARGET:-builder@linux-builder}"
      builder_gc_cmd="''${NDH_LINUX_BUILDER_GC_COMMAND:-sudo nix-collect-garbage -d}"
      echo "[tart-materialize][INFO] running pre-build GC on ''${builder_target}: ''${builder_gc_cmd}" >&2
      if ! ${pkgs.openssh}/bin/ssh -o BatchMode=yes "$builder_target" "$builder_gc_cmd"; then
        echo "[tart-materialize][WARN] pre-build GC on ''${builder_target} failed; continuing" >&2
      fi
    fi

    # ── Darwin VZ-host observer ──────────────────────────────────────────────
    # Runs in background, collects macOS-side metrics (memory pressure, disk I/O,
    # nix process CPU/RSS) during the entire materialize phase.
    # Output: NDH_DARWIN_OBS_OUTPUT (default ~/Library/Logs/nix-darwin-home/darwin-observe.yaml)
    _ndh_darwin_obs_enabled() { ''${NDH_BUILD_OBSERVE:-${
      if cfg.enableBuildObserve then "true" else "false"
    }}; }

    _ndh_darwin_obs_sample() {
      local ts nix_pid nix_cpu nix_rss
      ts=$(date -Iseconds)

      # Memory pressure via vm_stat (macOS; values in pages, page = 16 KiB on Apple Silicon)
      local pages_free pages_active pages_inactive pages_wired pages_compressed page_size
      page_size=$(pagesize 2>/dev/null || echo 16384)
      eval "$(vm_stat 2>/dev/null | ${pkgs.gawk}/bin/awk '
        /Pages free:/        {gsub(/\./,"",$NF); printf "pages_free=%s\n",       $NF}
        /Pages active:/      {gsub(/\./,"",$NF); printf "pages_active=%s\n",     $NF}
        /Pages inactive:/    {gsub(/\./,"",$NF); printf "pages_inactive=%s\n",   $NF}
        /Pages wired down:/  {gsub(/\./,"",$NF); printf "pages_wired=%s\n",      $NF}
        /Pages occupied.*compressor:/{gsub(/\./,"",$NF); printf "pages_compressed=%s\n", $NF}
      ')"
      local free_mb=$(( (''${pages_free:-0} * page_size) / 1048576 ))
      local wired_mb=$(( (''${pages_wired:-0} * page_size) / 1048576 ))
      local compressed_mb=$(( (''${pages_compressed:-0} * page_size) / 1048576 ))

      # Disk I/O snapshot (BSD iostat: 1 sample, all disks, KB units)
      local diskio
      diskio=$(iostat -d -K 2>/dev/null \
        | ${pkgs.gawk}/bin/awk 'NR>2 && $1!="" {
            printf "{\"dev\":\"%s\",\"kb_per_t\":%s,\"tps\":%s,\"mb_s\":%s},",
              $1, $2, $3, $4
          }' \
        | sed 's/,$//' | ${pkgs.gawk}/bin/awk '{print "["$0"]"}')
      [[ -n "$diskio" ]] || diskio="[]"

      # nix process stats (heaviest nix-daemon or nix build subprocess)
      nix_pid=$(pgrep -n "nix-daemon\|nix build" 2>/dev/null || echo "")
      if [[ -n "$nix_pid" ]]; then
        read -r nix_cpu nix_rss < <(
          ps -p "$nix_pid" -o %cpu=,rss= 2>/dev/null \
            | ${pkgs.gawk}/bin/awk '{printf "%s %d", $1, int($2/1024)}'
        )
      else
        nix_cpu="0" nix_rss="0"
      fi

      printf '%s\n' \
        '{"type":"darwin-sample","ts":"'"$ts"'","mem":{"free_mb":'"$free_mb"',"wired_mb":'"$wired_mb"',"compressed_mb":'"$compressed_mb"'},"diskio":'"$diskio"',"nix":{"pid":"'"$nix_pid"'","cpu_pct":'"''${nix_cpu:-0}"',"rss_mb":'"''${nix_rss:-0}"'}}' \
        >&"$_NDH_DARWIN_OBS_FD" 2>/dev/null || true
    }

    _ndh_darwin_obs_mark() {
      [[ -n "''${_NDH_DARWIN_OBS_FD:-}" ]] || return 0
      printf '%s\n' '{"type":"darwin-phase","label":"'"$1"'","ts":"'"$(date -Iseconds)"'"}' \
        >&"$_NDH_DARWIN_OBS_FD" 2>/dev/null || true
    }

    _ndh_darwin_obs_start() {
      _ndh_darwin_obs_enabled || return 0
      local interval="''${NDH_BUILD_OBSERVE_INTERVAL:-${toString cfg.buildObserveInterval}}"
      local out_file="''${NDH_DARWIN_OBS_OUTPUT:-$HOME/Library/Logs/nix-darwin-home/darwin-observe.yaml}"
      local pipe
      mkdir -p "$(dirname "$out_file")"
      pipe="$(mktemp -d)/darwin-obs.fifo"
      mkfifo "$pipe"
      _NDH_DARWIN_OBS_PIPE="$pipe"

      # Writer: one long-lived yq process converting JSON lines → YAML stream
      ( while IFS= read -r line; do
          printf '%s\n' "$line" | ${pkgs.yq-go}/bin/yq -p json -o yaml
          printf -- '---\n'
        done < "$pipe"
      ) >> "$out_file" &
      _NDH_DARWIN_OBS_WRITER_PID="$!"

      exec {_NDH_DARWIN_OBS_FD}>"$pipe"
      export _NDH_DARWIN_OBS_FD _NDH_DARWIN_OBS_WRITER_PID _NDH_DARWIN_OBS_PIPE

      printf '%s\n' '{"type":"darwin-meta","started":"'"$(date -Iseconds)"'","out_file":"'"$out_file"'"}' \
        >&"$_NDH_DARWIN_OBS_FD" 2>/dev/null || true

      ( while true; do _ndh_darwin_obs_sample; sleep "$interval"; done ) &
      _NDH_DARWIN_OBS_SAMPLER_PID="$!"
      export _NDH_DARWIN_OBS_SAMPLER_PID
    }

    _ndh_darwin_obs_stop() {
      _ndh_darwin_obs_enabled || return 0
      [[ -n "''${_NDH_DARWIN_OBS_SAMPLER_PID:-}" ]] && \
        kill "''${_NDH_DARWIN_OBS_SAMPLER_PID}" 2>/dev/null || true
      _ndh_darwin_obs_mark "darwin-stop"
      [[ -n "''${_NDH_DARWIN_OBS_FD:-}" ]] && exec {_NDH_DARWIN_OBS_FD}>&-
      [[ -n "''${_NDH_DARWIN_OBS_WRITER_PID:-}" ]] && \
        wait "''${_NDH_DARWIN_OBS_WRITER_PID}" 2>/dev/null || true
      [[ -n "''${_NDH_DARWIN_OBS_PIPE:-}" ]] && rm -f "''${_NDH_DARWIN_OBS_PIPE}" || true
    }

    _ndh_darwin_obs_start
    trap '_ndh_darwin_obs_stop' EXIT
    _ndh_darwin_obs_mark "materialize-start"

    ${tartActivationScript} "$@"
    _exit=$?

    _ndh_darwin_obs_mark "materialize-done"
    exit $_exit
  '';

  # Minimal deploy wrapper: the same activation script, but with only the
  # PATH dependencies it needs at runtime — no linux-builder GC, no Darwin
  # observer, no closure to a NixOS runtime system.  Designed to be `nix
  # copy`'d to a vz host that only consumes pre-built artifacts.  The bundle
  # is generic and fleet-wide; per-VM identity flows in at runtime via
  # `nerd-tart --config <YAML>`.
  tartDeployPackage = pkgs.writeShellScriptBin "nerd-tart" ''
    export PATH="${
      lib.makeBinPath [
        pkgs.gawk
        pkgs.gnused
        pkgs.coreutils
        pkgs.findutils
        pkgs.yq-go
        pkgs.util-linux
        pkgs.bash
      ]
    }:/usr/bin:/bin:/usr/sbin:/sbin"

    exec ${tartDeployActivationScript} "$@"
  '';

  tartRunManifest = pkgs.writeText "tart-${cfg.vmName}-run-manifest.yaml" ''
    # Generated Tart run manifest (@codebase)
    effective_host_name_default: ${builtins.toJSON effectiveHostName}
    profile_user_default: ${builtins.toJSON profileUser}
    profile_home_default: ${builtins.toJSON profileHome}
    vm_name: ${builtins.toJSON cfg.vmName}
    vm_disk_format: ${builtins.toJSON cfg.vmDiskFormat}
    vm_boot_disk_size_gib: ${builtins.toJSON cfg.vmBootDiskSizeGiB}
    vm_cpu_count: ${builtins.toJSON cfg.vmCpuCount}
    vm_memory_mib: ${builtins.toJSON cfg.vmMemoryMiB}
    vm_display_width: ${builtins.toJSON cfg.vmDisplayWidth}
    vm_display_height: ${builtins.toJSON cfg.vmDisplayHeight}
    vm_mac_address: ${builtins.toJSON cfg.vmMacAddress}
    data_disk_size_gib: ${builtins.toJSON cfg.vmDataDiskSizeGiB}
    bridge_interface: ${builtins.toJSON cfg.vmRunBridgeInterface}
    no_graphics_default: ${builtins.toJSON cfg.vmRunNoGraphics}
    use_vnc_experimental: ${builtins.toJSON cfg.vmRunUseVncExperimental}
    serial_enable_default: ${builtins.toJSON cfg.vmRunSerialEnable}
    serial_path_default: ${builtins.toJSON cfg.vmRunSerialPath}
    serial_bridge_enable_default: ${builtins.toJSON cfg.vmRunSerialBridgeEnable}
    serial_bridge_dir_default: ${builtins.toJSON cfg.vmRunSerialBridgeDir}
    serial_bridge_auto_screen_default: ${builtins.toJSON cfg.vmRunSerialBridgeAutoScreen}
    nested_virt_default: ${builtins.toJSON cfg.vmRunNestedVirt}
    raw_image_manifest_path_default: ${builtins.toJSON rawImageManifestPath}
    raw_image_store_path_default: ${builtins.toJSON rawImageStorePath}
    raw_image_source_path_default: ${builtins.toJSON cfg.rawImageSourcePath}
    raw_image_target_path_default: ${builtins.toJSON cfg.rawImageTargetPath}
    sops_age_host_dir_default: ${builtins.toJSON cfg.vmRunSopsAgeHostDir}
    sops_age_tag: ${builtins.toJSON cfg.vmRunSopsAgeTag}
    tart_bin: ${builtins.toJSON cfg.tartBinaryPath}
    diskutil_bin: ${builtins.toJSON cfg.diskutilBinaryPath}
  '';

  # Generic, host-agnostic.  The script self-resolves its run manifest from
  # NDH_TART_VM_CONFIG or $XDG_CONFIG_HOME/nerd-tart/<vm>.yaml at runtime,
  # so a single tartRunScript derivation is shared across the fleet.
  tartRunScript = ndh.store.runCommand "tart-nerd-tart-run.sh" { } ''
    cp ${
      pkgs.replaceVars ./tart-config.d/run.sh {
        nixBashTrampoline = nixBashTrampoline;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  options.tart.configGenerator = {
    # Operator-controlled gates, propagated from the flake via environment
    # variables at eval time.  The defaults below bake the resolved boolean
    # into the materializer shell script so `NDH_*` overrides at `tart-vm-
    # materialize` runtime remain effective without a re-eval.
    linuxBuilderGcBeforeBuild = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run `sudo nix-collect-garbage -d` on the linux-builder before each
        Tart materialize.  Baked as the default for `NDH_LINUX_BUILDER_GC_BEFORE_BUILD`.
      '';
    };

    enableBuildObserve = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Enable the build-time observer that samples macOS VZ-host metrics
        (memory / disk-I/O / nix-daemon) plus the nested builder/guest
        telemetry streams during materialize.  Baked as the default for
        `NDH_BUILD_OBSERVE`.
      '';
    };

    buildObserveInterval = mkOption {
      type = types.int;
      default = 5;
      description = ''
        Observer sample interval in seconds, shared across all source layers
        (VZ host, linux-builder, nested QEMU guest).  Baked as the default
        for `NDH_BUILD_OBSERVE_INTERVAL`.
      '';
    };

    vmName = mkOption {
      type = types.str;
      default = "nerd-nixos";
      description = ''
        Tart VM name to materialize for Linux guest runtime.
      '';
    };

    vmDiskFormat = mkOption {
      type = types.enum [
        "raw"
        "asif"
      ];
      default = "asif";
      description = ''
        Disk format for VM creation and persisted VM config (`config.json`).
        `asif` is the canonical format for Tart Linux runtime in this workflow.
      '';
    };

    vmBootDiskSizeGiB = mkOption {
      type = types.int;
      default = 16;
      description = ''
        Target VM boot disk size in GiB (EFI-only disk: ESP + kernel + initrd).
        In the ZFS layout /dev/vda holds only the boot partition — no root filesystem.
        All data lives on the ZFS data disks (vmDataDiskSizeGiB).
        Activation enforces this target size by recreating stale boot disks.
      '';
    };

    vmCpuCount = mkOption {
      type = types.int;
      default = 4;
      description = ''
        CPU count enforced via `tart set` during materialization.
      '';
    };

    vmMemoryMiB = mkOption {
      type = types.int;
      default = 8192;
      description = ''
        Memory size in MiB enforced via `tart set` during materialization.
      '';
    };

    vmDisplayWidth = mkOption {
      type = types.int;
      default = 1728;
      description = ''
        VM display width written to Tart `config.json`.
      '';
    };

    vmDisplayHeight = mkOption {
      type = types.int;
      default = 1080;
      description = ''
        VM display height written to Tart `config.json`.
      '';
    };

    vmMacAddress = mkOption {
      type = types.str;
      default = "10:66:6a:4c:${hostByteHex}:01";
      description = ''
        MAC address written to Tart `config.json` for LAN identity.
        Default aligns with Lima `vmlan0` MAC derivation for the same host.
      '';
    };

    vmRunBridgeInterface = mkOption {
      type = types.str;
      default = "";
      description = ''
        Bridged host network interface used by generated run wrapper.
        Set to a non-empty interface name (e.g. `en0`) to force bridged mode.
        Empty default keeps Tart's default networking mode.
      '';
    };

    vmRunNoGraphics = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Pass `--no-graphics` to `tart run` so the VM starts headless (no UI
        window).  Combine with `vmRunSerialBridgeEnable` to get a fully
        automated headless boot with serial console access.
        Override at runtime with `NO_GRAPHICS=0`.
      '';
    };

    vmRunUseVncExperimental = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether generated run wrapper uses `--vnc-experimental`.
        Mutually exclusive with `vmRunNoGraphics`; enabling both is an error.
      '';
    };

    vmRunSerialEnable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Temporary flag for Tart serial console support.
        Canonical behavior is currently disabled in the generated run wrapper
        while serial-path stability issues are under investigation.
      '';
    };

    vmRunSerialPath = mkOption {
      type = types.str;
      default = "";
      description = ''
        Optional externally managed serial endpoint path for Tart `--serial-path`.
        Can be overridden at runtime with `SERIAL_PATH`.
      '';
    };

    vmRunSerialBridgeEnable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Whether generated run wrapper auto-creates a stable PTY pair via `socat`
        when no explicit `SERIAL_PATH` is provided.
      '';
    };

    vmRunSerialBridgeDir = mkOption {
      type = types.str;
      default = "${profileHome}/.tart/vms/${cfg.vmName}/serial";
      description = ''
        Directory used by generated run wrapper for stable serial PTY symlinks.
        Wrapper creates `<vm>.tart` for Tart `--serial-path` and `<vm>.screen`
        for operator `screen` attachment.
      '';
    };

    vmRunSerialBridgeAutoScreen = mkOption {
      type = types.bool;
      default = false;
      description = ''
        When `vmRunSerialBridgeEnable` is true, automatically start a detached
        `screen(1)` session that logs serial console output to
        `<vm_disk_dir>/serial.log`.  Reattach with:
          screen -r <vm_name>-serial
        Override at runtime with `SERIAL_BRIDGE_AUTO_SCREEN=1`.
      '';
    };

    vmRunNestedVirt = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Pass `--nested` to `tart run` to enable nested virtualization
        (Apple Virtualization.framework nested VMs, macOS 15+).
        Required when the guest runs QEMU or other hypervisors.
        Override at runtime with `NESTED_VIRT=1`.
      '';
    };

    vmRunFirstBootAttachDiskPath = mkOption {
      type = types.str;
      default = "";
      description = ''
        Optional bootstrap disk image path attached as the last Tart external disk
        when root `disk.img` does not contain a detectable ZFS partition.
        Intended for bringup disk images used to run disko and install full NixOS
        onto target datasets.
      '';
    };

    vmRunFirstBootAttachDiskManifestPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional manifest path for `vmRunFirstBootAttachDiskPath` image.
        When set, activation/run validate manifest `bootLoader` against
        `vmRunFirstBootAttachDiskExpectedBootLoader`.
      '';
    };

    vmRunFirstBootAttachDiskExpectedBootLoader = mkOption {
      type = types.str;
      default = "systemd-boot";
      description = ''
        Expected bootloader value for first-boot attach disk manifest metadata.
      '';
    };

    vmRunFirstBootAttachDiskSizeGiB = mkOption {
      type = types.int;
      default = 24;
      description = ''
        Target size in GiB for VM-local copy of first-boot bootstrap disk (`nixos.img`).
        Keep this independent from `vmBootDiskSizeGiB`; bootstrap image should remain small
        (typically 16-24 GiB) while root VM disk can be larger.
      '';
    };

    vmRunFirstBootMarkerFile = mkOption {
      type = types.str;
      default = "${profileHome}/.tart/vms/${cfg.vmName}/.first-boot-bootstrap-disk.done";
      description = ''
        Reserved marker file path for bootstrap workflows.
      '';
    };

    vmRunSopsAgeHostDir = mkOption {
      type = types.str;
      default = "${profileHome}/.config/sops";
      description = ''
        Host directory shared into the Tart VM via virtiofs as the SOPS config root.
        The age key is expected at `<mountPoint>/age/keys.txt` inside the guest.
        Canonical behavior requires this share for in-guest SOPS bootstrap decryption.
      '';
    };

    vmRunSopsAgeTag = mkOption {
      type = types.str;
      default = "ndh-sops-age";
      description = ''
        Virtiofs mount tag used for the mandatory SOPS age host directory share.
      '';
    };

    vmDataDiskSizeGiB = mkOption {
      type = types.int;
      default = 100;
      description = ''
        Size in GiB for auto-created VM-local Tart data disks (`disk2`/`disk3`/`recover`)
        when missing in activation/materialization.
      '';
    };

    tartBinaryPath = mkOption {
      type = types.str;
      default = if tartPackageAvailable then "${pkgs.tart}/bin/tart" else "";
      description = ''
        Preferred absolute Tart CLI path used by activation and generated wrappers.
        Defaults to the Nix package path when `pkgs.tart` is available.
      '';
    };

    nixBinaryPath = mkOption {
      type = types.str;
      default = "${pkgs.nix}/bin/nix";
      description = ''
        Absolute nix CLI path used by Tart materialization fallback resolution.
      '';
    };

    diskutilBinaryPath = mkOption {
      type = types.str;
      default = "/usr/sbin/diskutil";
      description = ''
        Absolute diskutil path used for ASIF conversion/resizing on Darwin.
      '';
    };

    rawImageManifestPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional path to disk-image manifest output containing `manifest.yaml`.
        When provided, activation resolves the raw image through manifest metadata first.
      '';
    };

    runtimeSystemPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional store path of the full NixOS runtime system closure the operator
        will activate remotely once the minimal bringup image is up. When set, a
        closure edge is added to the Tart activation bundle so `nix build` of
        the materializer realises the full system in the same stage — the
        operator ends up with both the bringup disk image and the full
        toplevel ready for `nixos-rebuild switch --target-host`.
      '';
    };

    rawImageStorePath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Store-pinned path to a prebuilt raw `nixos.img` used as first-priority source.
      '';
    };

    rawImageSourcePath = mkOption {
      type = types.str;
      default = "";
      description = ''
        Optional direct fallback path for raw NixOS disk image.
      '';
    };

    rawImageTargetPath = mkOption {
      type = types.str;
      default = "/nix/var/nix/gcroots/per-user/${profileUser}/tart-${cfg.vmName}-materialize";
      description = ''
        Stable user gcroot symlink path pointing to the activation script store path.
        Because the activation script's Nix closure transitively includes the run
        manifest (which embeds disk image store paths), this single link keeps all
        bringup disk images alive without per-file or per-directory gcroot clutter.
      '';
    };

    imageFlakeAttr = mkOption {
      type = types.str;
      default = "nixosDiskImage";
      description = ''
        Flake output attribute used as fallback when rawImageSourcePath is unavailable.
      '';
    };

    nixosFlakePath = mkOption {
      type = types.str;
      default = "/var/lib/git/nxmatic/nix-darwin-home";
      description = ''
        Host-side flake path used for fallback raw image resolution.
      '';
    };

    enableActivationHook = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Run Tart VM materialization during darwin activation (`postActivation`).
        Enabled by default so `darwin-rebuild switch` keeps the VM configuration
        in sync. Existing disks are never overwritten — only missing disks are
        created and undersized disks produce a warning.
      '';
    };

    forceEnable = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Force-enable Tart materialization on this Darwin host even when inventory host
        VM manager metadata does not declare `tart` runtime support.
      '';
    };

    installMaterializerPackage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install the `nerd-tart-vm-materialize` helper package in system packages.
      '';
    };

    installTartPackage = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Install the Tart CLI package from Nix in system packages when available.
      '';
    };

    materializerPackage = mkOption {
      type = types.package;
      readOnly = true;
      default = tartMaterializerPackage;
      description = ''
        Store package exposing `nerd-tart-vm-materialize` for host-side Tart VM materialization.
      '';
    };

    deployPackage = mkOption {
      type = types.package;
      readOnly = true;
      default = tartDeployPackage;
      description = ''
        Store package exposing `nerd-tart` — the generic, host-agnostic
        sibling of `materializerPackage` for hosts that only consume
        pre-built artifacts.  Skips the runtime-system closure symlink, the
        linux-builder GC step, and the Darwin observability harness, so
        its closure is bounded by the disk-image references rather than
        the full NixOS runtime system.
      '';
    };

    runManifest = mkOption {
      type = types.package;
      readOnly = true;
      default = tartRunManifest;
      description = ''
        The per-host run manifest YAML carrying VM identity (vm_name,
        vm_mac_address, cpu/mem, disk sizes, run-time flags).  The flake
        exposes this as `<host>-tart-vm-config` so operators can `nix build`
        it and scp the result to the vz host's
        `$XDG_CONFIG_HOME/nerd-tart/<vm>.yaml`, where the generic
        `nerd-tart` deploy bundle reads it via `--config FILE`.
      '';
    };
  };

  config = {
    assertions = [
      {
        assertion = !(tartMaterializationEnabled && cfg.tartBinaryPath == "");
        message = ''
          tart.configGenerator.tartBinaryPath must be set when Tart materialization is enabled.
          Prefer Nix-provided path, e.g. "${pkgs.tart}/bin/tart".
        '';
      }
      {
        assertion = !(cfg.vmRunNoGraphics && cfg.vmRunUseVncExperimental);
        message = ''
          tart.configGenerator: vmRunNoGraphics and vmRunUseVncExperimental are mutually exclusive.
          Tart's --no-graphics and --vnc-experimental cannot be passed together.
        '';
      }
    ];

    environment.systemPackages =
      lib.optionals (tartMaterializationEnabled && cfg.installTartPackage && tartPackageAvailable) [
        pkgs.tart
      ]
      ++ lib.optionals (tartMaterializationEnabled && cfg.vmRunSerialBridgeEnable) [
        pkgs.socat
      ]
      ++ lib.optionals (tartMaterializationEnabled && cfg.installMaterializerPackage) [
        cfg.materializerPackage
      ];

    # User-level SSH matchBlock for direct SSH access to the Tart VM.
    # Uses ProxyCommand to resolve the VM's dynamic IP at connect time via `tart ip`.
    # Port 22 is the standard SSHD port inside the VM.
    # Guard: only requires tart binary to be configured (not full materialization).
    hm.programs.ssh.settings."${cfg.vmName}" = lib.mkIf (cfg.tartBinaryPath != "") {
      User = profileUser;
      ProxyCommand = "sh -c 'nc \"$(${cfg.tartBinaryPath} ip %h 2>/dev/null)\" 22'";
      StrictHostKeyChecking = "no";
      UserKnownHostsFile = "/dev/null";
      ServerAliveInterval = "30";
      ServerAliveCountMax = "3";
    };

    system.activationScripts.postActivation.text =
      lib.mkIf
        (
          config.vmMaterializer.enableActivationHook
          && tartMaterializationEnabled
          && cfg.enableActivationHook
          && cfg.rawImageManifestPath != null
        )
        (
          lib.mkAfter ''
            ${tartActivationScript}
          ''
        );
  };
}
