{
  config,
  lib,
  pkgs,
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
  activationCheckScript = pkgs.writeShellScript "ndh-bootstrap-profile-activation-check" ''
    set -euo pipefail

    profile_bin="${cfg.profileDir}/bin"
    auto_install="${if cfg.autoInstallOnActivation then "1" else "0"}"

    install_profile() {
      echo "[ndh-bootstrap-profile] installing/refreshing profile ${cfg.profileDir}" >&2
      nix profile add --profile "${cfg.profileDir}" "${bootstrapRuntimePackage}" >&2
    }

    check_commands() {
      missing=""
      wrong_source=""
      for cmd in ${requiredCommandsString}; do
        if ! resolved="$(command -v "$cmd" 2>/dev/null)"; then
          missing="$missing $cmd"
          continue
        fi

        case "$resolved" in
          "$profile_bin"/*) ;;
          *)
            wrong_source="$wrong_source $cmd:$resolved"
            ;;
        esac
      done
    }

    if [ ! -d "$profile_bin" ]; then
      if [ "$auto_install" = "1" ]; then
        install_profile
      else
        echo "[ndh-bootstrap-profile][ERROR] required profile bin directory is missing: $profile_bin" >&2
        echo "[ndh-bootstrap-profile][ERROR] install it first: ${installHint}" >&2
        exit 1
      fi
    fi

    export PATH="$profile_bin:$PATH"

    check_commands

    if { [ -n "$missing" ] || [ -n "$wrong_source" ]; } && [ "$auto_install" = "1" ]; then
      install_profile
      export PATH="$profile_bin:$PATH"
      check_commands
    fi

    if [ -n "$missing" ]; then
      echo "[ndh-bootstrap-profile][ERROR] missing required commands:$missing" >&2
      echo "[ndh-bootstrap-profile][ERROR] reinstall profile: ${installHint}" >&2
      exit 1
    fi

    if [ -n "$wrong_source" ]; then
      echo "[ndh-bootstrap-profile][ERROR] required commands not sourced from profile:$wrong_source" >&2
      echo "[ndh-bootstrap-profile][ERROR] reinstall/repair profile: ${installHint}" >&2
      exit 1
    fi
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

  config = lib.mkIf cfg.enable {
    environment.variables = {
      NDH_BOOTSTRAP_PROFILE_DIR = cfg.profileDir;
      NDH_BOOTSTRAP_PROFILE_BIN = "${cfg.profileDir}/bin";
      NDH_BOOTSTRAP_REQUIRED_COMMANDS = requiredCommandsString;
      NDH_BOOTSTRAP_STRICT = "1";
      NDH_BOOTSTRAP_INSTALL_HINT = installHint;
    };

    system.activationScripts.preActivation.text = lib.mkIf cfg.requireForActivation (lib.mkBefore ''
      ${activationCheckScript}
    '');
  };
}
