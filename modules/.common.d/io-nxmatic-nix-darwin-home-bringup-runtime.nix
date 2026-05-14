{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.ndh.bringupRuntime;
  ndhContext = ndh.context;
  installerCommand = "nerd-bringup-install";
  installerAttrDefault = "nerd-bringup-install";
  hostNameForAttr =
    if
      config ? profile
      && config.profile ? host
      && config.profile.host ? hostAlias
      && config.profile.host.hostAlias != null
      && config.profile.host.hostAlias != ""
    then
      config.profile.host.hostAlias
    else if
      config ? profile
      && config.profile ? host
      && config.profile.host ? hostName
      && config.profile.host.hostName != null
      && config.profile.host.hostName != ""
    then
      config.profile.host.hostName
    else
      null;
  installerAttr =
    if hostNameForAttr != null then "${hostNameForAttr}-bringup-install" else installerAttrDefault;
  storeNamePrefix = "io.nxmatic.nix-darwin-home";
  prefixStoreName =
    name: if lib.hasPrefix "${storeNamePrefix}-" name then name else "${storeNamePrefix}-${name}";
  requiredCommandsString = lib.concatStringsSep " " cfg.requiredCommands;
  installHint = "nix run .#${installerAttr} -- ${cfg.profileDir}";
  loggerShim = pkgs.writeShellScriptBin "logger" ''
    if [[ -x /usr/bin/logger ]]; then
      exec /usr/bin/logger "$@"
    fi
    if [[ -x /run/current-system/sw/bin/logger ]]; then
      exec /run/current-system/sw/bin/logger "$@"
    fi
    echo "[ndh][WARN] logger binary unavailable; message was: $*" >&2
    exit 0
  '';
  bootstrapRuntimePackage = pkgs.symlinkJoin {
    name = prefixStoreName "bringup-runtime-profile-holder";
    paths = with pkgs; [
      (lib.getBin bashInteractive)
      (lib.getBin config.nix.package)
      age
      coreutils-full
      findutils
      gawk
      git
      gnugrep
      gnused
      keychain
      loggerShim
      openssh
      yq-go
    ];
  };
  activationCheckSource =
    builtins.replaceStrings
      [
        "@profileBin@"
        "@nixBin@"
        "@autoInstall@"
        "@requiredCommands@"
        "@installHint@"
        "@runtimePackage@"
        "@bootstrapInstaller@"
        "@profileDir@"
      ]
      [
        "${cfg.profileDir}/bin"
        "${config.nix.package.out}/bin/nix"
        (if cfg.autoInstallOnActivation then "1" else "0")
        requiredCommandsString
        installHint
        "${bootstrapRuntimePackage}"
        "${ndhPrerequisitesInstallerPackage}/bin/${installerCommand}"
        cfg.profileDir
      ]
      (builtins.readFile ./bringup-runtime.d/activation-check.sh);
  # Activation check as a proper directory package — script lives in share/, not at the store root.
  # Defined after ndhPrerequisitesInstallerPackage due to @bootstrapInstaller@ reference.
  ndhActivationCheckPackage =
    pkgs.runCommand (prefixStoreName "bringup-runtime-activation-check") { }
      ''
        install -Dm755 ${pkgs.writeShellScript "activation-check" activationCheckSource} \
          "$out/share/activation-check.sh"
      '';
  # Canonical trampoline directory from the flake-level builder (single
  # version across initrd / activation / runtime — see
  # modules/.common.d/default.nix).
  trampolineDir = builtins.dirOf ndhContext.nixBashTrampoline;
  standaloneInstallSource =
    builtins.replaceStrings
      [
        "@nixBashTrampoline@"
        "@nix@"
        "@loggerTag@"
        "@runtimePackage@"
        "@defaultProfileDir@"
        "@requiredCommands@"
      ]
      [
        "${trampolineDir}/nix-bash-trampoline.sh"
        "${config.nix.package.out}/bin/nix"
        "ndh.bringup-runtime.install-standalone"
        "${bootstrapRuntimePackage}"
        cfg.profileDir
        requiredCommandsString
      ]
      (builtins.readFile ./bringup-runtime.d/install-standalone.sh);
  # Installer as a proper directory package — script lives in bin/, not at the store root.
  # standaloneInstallSource already has #!/usr/bin/env bash so writeTextFile is sufficient.
  ndhPrerequisitesInstallerPackage = pkgs.writeTextFile {
    name = prefixStoreName "bringup-runtime-profile-installer";
    text = standaloneInstallSource;
    executable = true;
    destination = "/bin/${installerCommand}";
  };
in
{
  options.ndh.bringupRuntime = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable dedicated Nix profile contract for NDH bringup runtime tools.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "io-nxmatic-nix-darwin-home-bringup-runtime";
      description = "Dedicated Nix profile name for NDH bringup runtime tools.";
    };

    profileDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/profiles/per-user/root/${cfg.name}";
      description = "Absolute Nix profile path used by NDH bringup runtime scripts.";
    };

    requiredCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "bash"
        "nix"
        "age"
        "age-keygen"
        "awk"
        "sed"
        "grep"
        "ssh"
        "ssh-keygen"
        "yq"
        "git"
        "logger"
      ];
      description = "Command contract that must be present in the dedicated bringup runtime profile.";
    };

    autoInstallOnActivation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "When true, activation installs/refreshes the dedicated bringup runtime profile before enforcing command checks.";
    };

    requireForActivation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Fail activation if dedicated bringup runtime profile is missing/incomplete.";
    };

    # Packages exposed for platform modules to consume. Read-only — built
    # here, used by (e.g.) modules/nixos/bringup-runtime.nix to wire the
    # systemd unit that installs the profile on first boot.
    runtimePackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "symlinkJoin derivation holding the full bringup runtime command set.";
    };

    installerPackage = lib.mkOption {
      type = lib.types.package;
      readOnly = true;
      description = "Standalone installer (writeTextFile) that materializes runtimePackage into a Nix profile.";
    };

    installerCommand = lib.mkOption {
      type = lib.types.str;
      readOnly = true;
      description = "Name of the installer binary inside installerPackage (bin/<name>).";
    };
  };

  config = lib.mkIf cfg.enable {
    # Canonical policy (@codebase): always install/refresh NDH bringup
    # prerequisites during activation.
    ndh.bringupRuntime = {
      autoInstallOnActivation = lib.mkForce true;
      runtimePackage = bootstrapRuntimePackage;
      installerPackage = ndhPrerequisitesInstallerPackage;
      inherit installerCommand;
    };

    environment.variables = {
      NDH_BOOTSTRAP_PROFILE_OWNER = "root";
      NDH_BOOTSTRAP_PROFILE_DIR = cfg.profileDir;
      NDH_BOOTSTRAP_PROFILE_BIN = "${cfg.profileDir}/bin";
      NDH_BOOTSTRAP_INSTALL_ATTR = installerAttr;
      NDH_BOOTSTRAP_RUNTIME_PACKAGE = "${bootstrapRuntimePackage}";
      NDH_BOOTSTRAP_INSTALLER = "${ndhPrerequisitesInstallerPackage}/bin/${installerCommand}";
      NDH_BOOTSTRAP_REQUIRED_COMMANDS = requiredCommandsString;
      NDH_BOOTSTRAP_STRICT = if cfg.requireForActivation then "1" else "0";
      NDH_BOOTSTRAP_INSTALL_HINT = installHint;
    };

    # preActivation is a cross-platform nix activation phase (both nix-
    # darwin and NixOS honour it). Safe to keep here.
    system.activationScripts.preActivation.text = lib.mkOrder 0 ''
      ${ndhActivationCheckPackage}/share/activation-check.sh
    '';
  };
}
