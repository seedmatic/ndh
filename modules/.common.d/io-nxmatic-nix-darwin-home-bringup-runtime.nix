{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.ndh.bringupRuntime;
  installerCommand = "ndh-bringup-install";
  installerAttr = "ndh-bringup-install";
  storeNamePrefix = "io.nxmatic.nix-darwin-home";
  prefixStoreName =
    name: if lib.hasPrefix "${storeNamePrefix}-" name then name else "${storeNamePrefix}-${name}";
  requiredCommandsString = lib.concatStringsSep " " cfg.requiredCommands;
  installHint = "nix run .#${installerAttr} -- ${cfg.profileDir}";
  loggerScript =
    if config ? nixBashLogger && config.nixBashLogger ? script then
      config.nixBashLogger.script
    else
      pkgs.writeText (prefixStoreName "logger.sh") ''
        #!${pkgs.bash}/bin/bash
        LOGGER_CMD=""
        source ${./shell.d/logger.sh}
      '';
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
  activationCheckSource = pkgs.replaceVars ./bringup-runtime.d/activation-check.sh {
    profileBin = "${cfg.profileDir}/bin";
    nixBin = "${config.nix.package.out}/bin/nix";
    autoInstall = if cfg.autoInstallOnActivation then "1" else "0";
    requiredCommands = requiredCommandsString;
    installHint = installHint;
    runtimePackage = bootstrapRuntimePackage;
    bootstrapInstaller = "${ndhPrerequisitesInstallerPackage}/bin/${installerCommand}";
    profileDir = cfg.profileDir;
  };
  activationCheckScript = pkgs.writeShellScript (prefixStoreName "bringup-runtime-activation-check") (
    builtins.readFile activationCheckSource
  );
  standaloneInstallSource = pkgs.replaceVars ./bringup-runtime.d/install-standalone.sh {
    bash = "${pkgs.bash}/bin/bash";
    nix = "${config.nix.package.out}/bin/nix";
    logger = loggerScript;
    loggerTag = "ndh.bringup-runtime.install-standalone";
    runtimePackage = bootstrapRuntimePackage;
    defaultProfileDir = cfg.profileDir;
    requiredCommands = requiredCommandsString;
  };
  ndhPrerequisitesInstallerPackage =
    pkgs.runCommand (prefixStoreName "bringup-runtime-profile-installer") { }
      ''
        install -Dm755 ${standaloneInstallSource} "$out/bin/${installerCommand}"
      '';
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
  };

  config = lib.mkIf cfg.enable (
    {
      # Canonical policy (@codebase): always install/refresh NDH bringup
      # prerequisites during activation.
      ndh.bringupRuntime.autoInstallOnActivation = lib.mkForce true;

      environment.variables = {
        NDH_BOOTSTRAP_PROFILE_OWNER = "root";
        NDH_BOOTSTRAP_PROFILE_DIR = cfg.profileDir;
        NDH_BOOTSTRAP_PROFILE_BIN = "${cfg.profileDir}/bin";
        NDH_BOOTSTRAP_RUNTIME_PACKAGE = "${bootstrapRuntimePackage}";
        NDH_BOOTSTRAP_INSTALLER = "${ndhPrerequisitesInstallerPackage}/bin/${installerCommand}";
        NDH_BOOTSTRAP_REQUIRED_COMMANDS = requiredCommandsString;
        NDH_BOOTSTRAP_STRICT = if cfg.requireForActivation then "1" else "0";
        NDH_BOOTSTRAP_INSTALL_HINT = installHint;
      };

      system.activationScripts.preActivation.text = lib.mkOrder 0 ''
        ${activationCheckScript}
      '';
    }
    // lib.optionalAttrs (options ? systemd) {

      # Keep installer command available in the NixOS system closure, including
      # bootstrap images where we need explicit/manual profile installation.
      environment.systemPackages = [ ndhPrerequisitesInstallerPackage ];

      # Seed canonical runtime profile links as declarative host policy so
      # scripts do not need to mutate profile state via shell trampoline.
      systemd.tmpfiles.rules = [
        "d /nix/var/nix/profiles/per-user/root 0755 root root -"
        "L+ ${cfg.profileDir} - - - - ${bootstrapRuntimePackage}"
      ]
      ++ lib.optionals (config.profile.user.name != "root") [
        "d /nix/var/nix/profiles/per-user/${config.profile.user.name} 0755 root root -"
        "L+ /nix/var/nix/profiles/per-user/${config.profile.user.name}/${cfg.name} - - - - ${bootstrapRuntimePackage}"
      ];

      # `nixos-rebuild boot` does not run activation on the currently running system.
      # Ensure the bringup runtime profile is provisioned at next boot before
      # services that rely on the command contract.
      systemd.services.io-nxmatic-nix-darwin-home-bringup-runtime-install = {
        description = "Install NDH bringup runtime profile for root (@codebase)";
        wantedBy = [ "multi-user.target" ];
        requiredBy = [
          "sops-install-secrets.service"
          "io-nxmatic-nix-darwin-home-hostkey-enrollment-check.service"
        ];
        before = [
          "sops-age-bootstrap.service"
          "sops-install-secrets.service"
          "io-nxmatic-nix-darwin-home-hostkey-enrollment-check.service"
        ];
        path = [
          pkgs.bash
          config.nix.package
        ];
        serviceConfig = {
          Type = "oneshot";
        };
        script = ''
          set -euo pipefail

          profile_dir_root="/nix/var/nix/profiles/per-user/root/${cfg.name}"
          profile_user="${config.profile.user.name}"
          profile_dir_user="/nix/var/nix/profiles/per-user/${config.profile.user.name}/${cfg.name}"

          mkdir -p /nix/var/nix/profiles/per-user/root
          mkdir -p "/nix/var/nix/profiles/per-user/${config.profile.user.name}"

          ${ndhPrerequisitesInstallerPackage}/bin/${installerCommand} "$profile_dir_root"

          if [ "$profile_user" != "root" ]; then
            ${ndhPrerequisitesInstallerPackage}/bin/${installerCommand} "$profile_dir_user"
          fi
        '';
      };
    }
  );
}
