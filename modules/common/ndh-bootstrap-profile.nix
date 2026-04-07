{
  config,
  lib,
  pkgs,
  options,
  ...
}:
let
  cfg = config.nxmatic.bootstrapProfile;
  requiredCommandsString = lib.concatStringsSep " " cfg.requiredCommands;
  installHint = "nix run .#ndh-prerequisites-install -- ${cfg.profileDir}";
  bootstrapRuntimePackage = pkgs.symlinkJoin {
    name = "ndh-bootstrap-runtime-activation";
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
  activationCheckScript = pkgs.writeShellScript "ndh-bootstrap-profile-activation-check" (builtins.readFile activationCheckSource);
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
      default = "ndh-bootstrap-runtime";
      description = "Dedicated Nix profile name for NDH bootstrap runtime tools.";
    };

    profileDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.profile.user.home}/.local/state/nix/profiles/${cfg.name}";
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
    environment.variables = {
      NDH_BOOTSTRAP_PROFILE_DIR = cfg.profileDir;
      NDH_BOOTSTRAP_PROFILE_BIN = "${cfg.profileDir}/bin";
      NDH_BOOTSTRAP_REQUIRED_COMMANDS = requiredCommandsString;
      NDH_BOOTSTRAP_STRICT = if cfg.requireForActivation then "1" else "0";
      NDH_BOOTSTRAP_INSTALL_HINT = installHint;
    };

    system.activationScripts.preActivation.text = lib.mkIf cfg.requireForActivation (lib.mkBefore ''
      ${activationCheckScript}
    '');
    }
    // lib.optionalAttrs (options ? systemd) {

    # `nixos-rebuild boot` does not run activation on the currently running system.
    # Ensure the bootstrap runtime profile is provisioned at next boot before
    # services that rely on the bootstrap command contract.
    systemd.services.ndh-bootstrap-profile-install = {
      description = "Install NDH bootstrap runtime profile for root (@codebase)";
      wantedBy = [ "multi-user.target" ];
      requiredBy = [
        "sops-install-secrets.service"
        "ndh-hostkey-enrollment-check.service"
      ];
      before = [
        "sops-age-bootstrap.service"
        "sops-install-secrets.service"
        "ndh-hostkey-enrollment-check.service"
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

        ${config.nix.package.out}/bin/nix profile add --profile "$profile_dir_root" "${bootstrapRuntimePackage}"

        if [ "$profile_user" != "root" ]; then
          ${config.nix.package.out}/bin/nix profile add --profile "$profile_dir_user" "${bootstrapRuntimePackage}"
        fi
      '';
    };
    }
  );
}
