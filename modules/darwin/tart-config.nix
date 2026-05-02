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
  tartMaterializationEnabled = tartRuntimeSupported || cfg.forceEnable;

  cfg = config.tart.configGenerator;
  tartPackageAvailable = pkgs ? tart;

  rawImageManifestPath =
    if cfg.rawImageManifestPath == null then "" else toString cfg.rawImageManifestPath;
  rawImageStorePath = if cfg.rawImageStorePath == null then "" else toString cfg.rawImageStorePath;
  firstBootAttachDiskManifestPath =
    if cfg.vmRunFirstBootAttachDiskManifestPath == null then
      ""
    else
      toString cfg.vmRunFirstBootAttachDiskManifestPath;

  # Helper-only activation function library for run.sh recovery/bootstrap logic.
  # Intentionally does not depend on tartRunScript to avoid derivation cycles.
  tartActivationHelperLib = ndh.store.runCommand "tart-${cfg.vmName}-activation-lib.sh" { } ''
    cp ${
      pkgs.replaceVars ./tart-config.d/activation.sh {
        nixBashTrampoline = nixBashTrampoline;
        manifestPath = tartRunManifest;
        tartRunScript = "";
      }
    } "$out"
    chmod +x "$out"
  '';

  tartActivationScript = ndh.store.runCommand "tart-${cfg.vmName}-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./tart-config.d/activation.sh {
        nixBashTrampoline = nixBashTrampoline;
        manifestPath = tartRunManifest;
        tartRunScript = tartRunScript;
      }
    } "$out"
    chmod +x "$out"
  '';

  tartMaterializerPackage = pkgs.writeShellScriptBin "nerd-nixos-tart-vm-materialize" ''
    if [[ "''${NDH_LINUX_BUILDER_GC_BEFORE_BUILD:-1}" == "1" ]]; then
      builder_target="''${NDH_LINUX_BUILDER_GC_TARGET:-builder@linux-builder}"
      builder_gc_cmd="''${NDH_LINUX_BUILDER_GC_COMMAND:-sudo nix-collect-garbage -d}"
      echo "[tart-materialize][INFO] running pre-build GC on ''${builder_target}: ''${builder_gc_cmd}" >&2
      if ! ssh -o BatchMode=yes "$builder_target" "$builder_gc_cmd"; then
        echo "[tart-materialize][WARN] pre-build GC on ''${builder_target} failed; continuing" >&2
      fi
    fi

    exec ${tartActivationScript} "$@"
  '';

  tartRunManifest = pkgs.writeText "tart-${cfg.vmName}-run-manifest.yaml" ''
    # Generated Tart run manifest (@codebase)
    effective_host_name_default: ${builtins.toJSON effectiveHostName}
    profile_user_default: ${builtins.toJSON profileUser}
    profile_home_default: ${builtins.toJSON profileHome}
    vm_name: ${builtins.toJSON cfg.vmName}
    vm_disk_format: ${builtins.toJSON cfg.vmDiskFormat}
    vm_disk_size_gib: ${builtins.toJSON cfg.vmDiskSizeGiB}
    vm_cpu_count: ${builtins.toJSON cfg.vmCpuCount}
    vm_memory_mib: ${builtins.toJSON cfg.vmMemoryMiB}
    vm_display_width: ${builtins.toJSON cfg.vmDisplayWidth}
    vm_display_height: ${builtins.toJSON cfg.vmDisplayHeight}
    vm_mac_address: ${builtins.toJSON cfg.vmMacAddress}
    data_disk_size_gib: ${builtins.toJSON cfg.vmDataDiskSizeGiB}
    bridge_interface: ${builtins.toJSON cfg.vmRunBridgeInterface}
    use_vnc_experimental: ${builtins.toJSON cfg.vmRunUseVncExperimental}
    serial_enable_default: ${builtins.toJSON cfg.vmRunSerialEnable}
    serial_path_default: ${builtins.toJSON cfg.vmRunSerialPath}
    serial_bridge_enable_default: ${builtins.toJSON cfg.vmRunSerialBridgeEnable}
    serial_bridge_dir_default: ${builtins.toJSON cfg.vmRunSerialBridgeDir}
    first_boot_attach_disk_path_default: ${builtins.toJSON cfg.vmRunFirstBootAttachDiskPath}
    first_boot_attach_disk_manifest_path_default: ${builtins.toJSON firstBootAttachDiskManifestPath}
    first_boot_attach_disk_boot_loader_expected: ${builtins.toJSON cfg.vmRunFirstBootAttachDiskExpectedBootLoader}
    first_boot_attach_disk_size_gib: ${builtins.toJSON cfg.vmRunFirstBootAttachDiskSizeGiB}
    first_boot_marker_file_default: ${builtins.toJSON cfg.vmRunFirstBootMarkerFile}
    raw_image_manifest_path_default: ${builtins.toJSON rawImageManifestPath}
    raw_image_store_path_default: ${builtins.toJSON rawImageStorePath}
    raw_image_source_path_default: ${builtins.toJSON cfg.rawImageSourcePath}
    raw_image_target_path_default: ${builtins.toJSON cfg.rawImageTargetPath}
    sops_age_host_dir_default: ${builtins.toJSON cfg.vmRunSopsAgeHostDir}
    sops_age_tag: ${builtins.toJSON cfg.vmRunSopsAgeTag}
    ndh_toplevel_host_dir_default: ${builtins.toJSON cfg.vmRunNdhTopLevelHostDir}
    ndh_toplevel_tag: ${builtins.toJSON cfg.vmRunNdhTopLevelTag}
    tart_bin: ${builtins.toJSON cfg.tartBinaryPath}
    diskutil_bin: ${builtins.toJSON cfg.diskutilBinaryPath}
  '';

  tartRunScript = ndh.store.runCommand "tart-${cfg.vmName}-run.sh" { } ''
    cp ${
      pkgs.replaceVars ./tart-config.d/run.sh {
        nixBashTrampoline = nixBashTrampoline;
        manifestPath = tartRunManifest;
        tartActivationScript = tartActivationHelperLib;
      }
    } "$out"
    chmod +x "$out"
  '';
in
{
  options.tart.configGenerator = {
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

    vmDiskSizeGiB = mkOption {
      type = types.int;
      default = 100;
      description = ''
        Target VM disk size in GiB for Tart root disk.
        Canonical default is 100 GiB for Tart ZFS lab capacity.
        Activation enforces this target size by recreating stale root disks.
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
      default = 4096;
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

    vmRunUseVncExperimental = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether generated run wrapper uses `--vnc-experimental`.
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
        Keep this independent from `vmDiskSizeGiB`; bootstrap image should remain small
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
      default = "${profileHome}/.config/sops/age";
      description = ''
        Host directory containing `keys.txt` exported to Tart VM via virtiofs.
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

    vmRunNdhTopLevelHostDir = mkOption {
      type = types.str;
      default = cfg.nixosFlakePath;
      description = ''
        Host NDH repository top-level directory optionally exported to Tart guest
        during bootstrap detection (blank/non-ZFS root disk path).
      '';
    };

    vmRunNdhTopLevelTag = mkOption {
      type = types.str;
      default = "ndh-toplevel";
      description = ''
        Virtiofs mount tag used for NDH top-level host directory export.
        Keep this aligned with guest mount expectations.
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
      default = "/nix/var/nix/gcroots/per-user/${profileUser}/tart-${cfg.vmName}";
      description = ''
        Stable user gcroot symlink path pointing to the nix store output directory
        containing the bringup disk images. A single directory link keeps all images
        in the store path alive and avoids per-file gcroot clutter.
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
        Run Tart raw->ASIF materialization during darwin activation (`postActivation`).
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
        Install the `nerd-nixos-tart-vm-materialize` helper package in system packages.
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
        Store package exposing `nerd-nixos-tart-vm-materialize` for host-side Tart VM materialization.
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

    system.activationScripts.postActivation.text =
      lib.mkIf (tartMaterializationEnabled && cfg.enableActivationHook)
        (
          lib.mkAfter ''
            ${tartActivationScript}
          ''
        );
  };
}
