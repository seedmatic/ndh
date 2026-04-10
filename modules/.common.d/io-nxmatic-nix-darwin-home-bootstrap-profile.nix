{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.nxmatic.bootstrapProfile;
  storeNamePrefix = "io.nxmatic.nix-darwin-home";
  prefixStoreName =
    name:
    if lib.hasPrefix "${storeNamePrefix}-" name then name else "${storeNamePrefix}-${name}";
  requiredCommandsString = lib.concatStringsSep " " cfg.requiredCommands;
  installHint = "nix run .#io-nxmatic-nix-darwin-home-prerequisites-install -- ${cfg.profileDir}";
  bootstrapRuntimePackage = pkgs.symlinkJoin {
    name = prefixStoreName "bootstrap-runtime-activation";
    paths = with pkgs; [
      age
      coreutils-full
      findutils
      gawk
      git
      gnugrep
      gnused
      keychain
      openssh
      yq-go
    ];
  };
  activationCheckSource = pkgs.replaceVars ./bootstrap-profile.d/activation-check.sh {
    profileBin = "${cfg.profileDir}/bin";
    nixBin = "${config.nix.package.out}/bin/nix";
    autoInstall = if cfg.autoInstallOnActivation then "1" else "0";
    requiredCommands = requiredCommandsString;
    installHint = installHint;
    runtimePackage = bootstrapRuntimePackage;
    profileDir = cfg.profileDir;
  };
  activationCheckScript = pkgs.writeShellScript (prefixStoreName "bootstrap-profile-activation-check") (builtins.readFile activationCheckSource);
  standaloneInstallSource = pkgs.replaceVars ./bootstrap-profile.d/install-standalone.sh {
    runtimePackage = bootstrapRuntimePackage;
    defaultProfileDir = cfg.profileDir;
    requiredCommands = requiredCommandsString;
  };
  ndhPrerequisitesInstallerPackage = pkgs.runCommand (prefixStoreName "prerequisites-install") { } ''
    install -Dm755 ${standaloneInstallSource} "$out/bin/io-nxmatic-nix-darwin-home-prerequisites-install"
  '';
in
{
  options.nxmatic.bootstrapProfile = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Enable dedicated Nix profile contract for NDH bootstrap runtime tools.";
    };

    name = lib.mkOption {
      type = lib.types.str;
      default = "io-nxmatic-nix-darwin-home-bootstrap-runtime";
      description = "Dedicated Nix profile name for NDH bootstrap runtime tools.";
    };

    profileDir = lib.mkOption {
      type = lib.types.str;
      default = "/nix/var/nix/profiles/per-user/root/${cfg.name}";
      description = "Absolute Nix profile path used by NDH bootstrap runtime scripts.";
    };

    requiredCommands = lib.mkOption {
      type = lib.types.listOf lib.types.str;
      default = [
        "age"
        "age-keygen"
        "awk"
        "sed"
        "grep"
        "ssh"
        "ssh-keygen"
        "yq"
        "git"
      ];
      description = "Command contract that must be present in the dedicated bootstrap profile.";
    };

    autoInstallOnActivation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "When true, activation installs/refreshes the dedicated bootstrap profile before enforcing command checks.";
    };

    requireForActivation = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Fail activation if dedicated bootstrap profile is missing/incomplete.";
    };
  };

  config = lib.mkIf cfg.enable (
    {
    # Canonical policy (@codebase): always install/refresh NDH bootstrap
    # prerequisites during activation.
    nxmatic.bootstrapProfile.autoInstallOnActivation = lib.mkForce true;

    environment.variables = {
      NDH_BOOTSTRAP_PROFILE_OWNER = "root";
      NDH_BOOTSTRAP_PROFILE_DIR = cfg.profileDir;
      NDH_BOOTSTRAP_PROFILE_BIN = "${cfg.profileDir}/bin";
      NDH_BOOTSTRAP_RUNTIME_PACKAGE = "${bootstrapRuntimePackage}";
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

    # `nixos-rebuild boot` does not run activation on the currently running system.
    # Ensure the bootstrap runtime profile is provisioned at next boot before
    # services that rely on the bootstrap command contract.
    systemd.services.io-nxmatic-nix-darwin-home-bootstrap-profile-install = {
      description = "Install NDH bootstrap runtime profile for root (@codebase)";
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
      serviceConfig = {
        Type = "oneshot";
      };
      script = ''
        set -euo pipefail

        profile_dir_root="/nix/var/nix/profiles/per-user/root/${cfg.name}"
        profile_user="${config.profile.user.name}"
        profile_dir_user="/nix/var/nix/profiles/per-user/${config.profile.user.name}/${cfg.name}"
        runtime_name="io.nxmatic.nix-darwin-home-bootstrap-runtime-activation"
        legacy_runtime_name="io.nxmatic.nix-darwin-home-bootstrap-runtime"

        mkdir -p /nix/var/nix/profiles/per-user/root
        mkdir -p "/nix/var/nix/profiles/per-user/${config.profile.user.name}"

        ${config.nix.package.out}/bin/nix profile remove --profile "$profile_dir_root" "$runtime_name" >/dev/null 2>&1 || true
        ${config.nix.package.out}/bin/nix profile remove --profile "$profile_dir_root" "$legacy_runtime_name" >/dev/null 2>&1 || true
        ${config.nix.package.out}/bin/nix profile add --profile "$profile_dir_root" "${bootstrapRuntimePackage}"

        if [ "$profile_user" != "root" ]; then
          ${config.nix.package.out}/bin/nix profile remove --profile "$profile_dir_user" "$runtime_name" >/dev/null 2>&1 || true
          ${config.nix.package.out}/bin/nix profile remove --profile "$profile_dir_user" "$legacy_runtime_name" >/dev/null 2>&1 || true
          ${config.nix.package.out}/bin/nix profile add --profile "$profile_dir_user" "${bootstrapRuntimePackage}"
        fi
      '';
    };
    }
  );
}
