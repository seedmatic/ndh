# Tart raw->ASIF image materialization (@codebase)
# Generates stable gcroot links for raw and ASIF images used by Tart workflows.

{
  config,
  pkgs,
  lib,
  catalog,
  ndh,
  ...
}:

let
  inherit (lib) mkOption types;

  profileUser = config.profile.user.name;
  profileHome = config.profile.user.home;
  profileHost = config.profile.host;
  loggerScript = config.nixBashLogger.script;

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

  hostCatalogEntries =
    lib.attrByPath
      [
        "hosts"
        effectiveHostName
      ]
      [ ]
      catalog;

  tartRuntimeSupported = lib.any (
    entry: (entry ? vm) && (entry.vm ? manager) && entry.vm.manager == "tart"
  ) hostCatalogEntries;
  tartMaterializationEnabled = tartRuntimeSupported || cfg.forceEnable;

  cfg = config.tart.configGenerator;
  tartPackageAvailable = pkgs ? tart;
  limaDiskSizeGiB =
    if config ? lima && config.lima ? configGenerator && config.lima.configGenerator ? diskSizeGiB then
      config.lima.configGenerator.diskSizeGiB
    else
      24;

  rawImageDescriptorPath =
    if cfg.rawImageDescriptorPath == null then "" else toString cfg.rawImageDescriptorPath;
  rawImageStorePath = if cfg.rawImageStorePath == null then "" else toString cfg.rawImageStorePath;

  tartActivationScript = ndh.store.runCommand "tart-${cfg.vmName}-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./tart-config.d/activation.sh {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        effectiveHostName = effectiveHostName;
        profileUser = profileUser;
        profileHome = profileHome;
        vmName = cfg.vmName;
        vmDiskFormat = cfg.vmDiskFormat;
        vmDiskSizeGiB = toString cfg.vmDiskSizeGiB;
        vmCpuCount = toString cfg.vmCpuCount;
        vmMemoryMiB = toString cfg.vmMemoryMiB;
        vmDisplayWidth = toString cfg.vmDisplayWidth;
        vmDisplayHeight = toString cfg.vmDisplayHeight;
        vmMacAddress = cfg.vmMacAddress;
        vmDataDiskSizeGiB = toString cfg.vmDataDiskSizeGiB;
        tartBinaryPath = cfg.tartBinaryPath;
        nixBinaryPath = cfg.nixBinaryPath;
        diskutilBinaryPath = cfg.diskutilBinaryPath;
        hdiutilBinaryPath = cfg.hdiutilBinaryPath;
        truncateBinaryPath = "${pkgs.coreutils}/bin/truncate";
        tartRunScript = tartRunScript;
        rawImageDescriptorPath = rawImageDescriptorPath;
        rawImageStorePath = rawImageStorePath;
        rawImageSourcePath = cfg.rawImageSourcePath;
        rawImageTargetPath = cfg.rawImageTargetPath;
        asifImageTargetPath = cfg.asifImageTargetPath;
        imageFlakeAttr = cfg.imageFlakeAttr;
        nixosFlakePath = cfg.nixosFlakePath;
        logger = loggerScript;
      }
    } "$out"
    chmod +x "$out"
  '';

  tartMaterializerPackage = pkgs.writeShellScriptBin "ndh-vm-tart-materialize" ''
    exec ${tartActivationScript} "$@"
  '';

  tartRunScript = ndh.store.runCommand "tart-${cfg.vmName}-run.sh" { } ''
    cp ${
      pkgs.replaceVars ./tart-config.d/run.sh {
        bashTrampoline = "${../.common.d/shell.d/nix-bash-trampoline.sh}";
        vmName = cfg.vmName;
        vmRunBridgeInterface = cfg.vmRunBridgeInterface;
        vmRunUseVncExperimental = if cfg.vmRunUseVncExperimental then "1" else "0";
        vmRunSopsAgeShareEnable = if cfg.vmRunSopsAgeShareEnable then "1" else "0";
        vmRunSopsAgeHostDir = cfg.vmRunSopsAgeHostDir;
        vmRunSopsAgeTag = cfg.vmRunSopsAgeTag;
        tartBinaryPath = cfg.tartBinaryPath;
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
      default = limaDiskSizeGiB;
      description = ''
        Target VM disk size in GiB for Tart root disk.
        Defaults to Lima nerd-nixos disk size to keep provider parity.
        Materialization expands the converted ASIF root image to this size.
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

    vmRunSopsAgeShareEnable = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Whether generated run wrapper attaches the host SOPS age directory
        as a read-only Tart directory share.
      '';
    };

    vmRunSopsAgeHostDir = mkOption {
      type = types.str;
      default = "${profileHome}/.config/sops/age";
      description = ''
        Host directory containing `keys.txt` to be exposed to the Tart VM via
        `--dir` for SOPS age key bootstrap import.
      '';
    };

    vmRunSopsAgeTag = mkOption {
      type = types.str;
      default = "ndh-sops-age";
      description = ''
        Virtiofs mount tag used for the SOPS age host directory share.
        Guest mounts this tag at `/mnt/tart-cidata/.sops.d`.
      '';
    };

    vmDataDiskSizeGiB = mkOption {
      type = types.int;
      default = 100;
      description = ''
        Size in GiB for auto-created Tart data disks (tank1/tank2/tank3/recover)
        when missing in the generated run wrapper.
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

    hdiutilBinaryPath = mkOption {
      type = types.str;
      default = "/usr/bin/hdiutil";
      description = ''
        Absolute hdiutil path used as deterministic resize fallback on Darwin.
      '';
    };

    rawImageDescriptorPath = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = ''
        Optional path to disk-image descriptor output containing `descriptor.yaml`.
        When provided, activation resolves the raw image through descriptor metadata first.
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
      default = "/nix/var/nix/gcroots/per-user/${profileUser}/tart-nixos.raw.img";
      description = ''
        Stable user gcroot symlink path for raw NixOS disk image used for ASIF conversion.
      '';
    };

    asifImageTargetPath = mkOption {
      type = types.str;
      default = "/nix/var/nix/gcroots/per-user/${profileUser}/tart-nixos.asif";
      description = ''
        Stable user gcroot symlink path for the generated ASIF image.
        The materializer also installs this ASIF image into `${config.tart.configGenerator.vmName}` VM disk.
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
        Force-enable Tart materialization on this Darwin host even when catalog host
        VM manager metadata does not declare `tart` runtime support.
      '';
    };

    installMaterializerPackage = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Install the `ndh-vm-tart-materialize` helper package in system packages.
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
        Store package exposing `ndh-vm-tart-materialize` for host-side Tart VM materialization.
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
