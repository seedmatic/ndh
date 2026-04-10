{ config, lib, ... }:
let
  cfg = config.nxmatic.etcBackup;
  etcTargets = builtins.attrNames config.environment.etc;
  etcTargetsLines = lib.concatStringsSep "\n" etcTargets;
in
{
  options.nxmatic.etcBackup = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Back up existing /etc targets before NixOS etc activation.";
    };

    extension = lib.mkOption {
      type = lib.types.str;
      default = "nix-backup";
      description = "Backup extension appended to /etc paths when preserving conflicts.";
    };

    overwrite = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Overwrite existing backup files before writing a new backup.";
    };
  };

  config = lib.mkIf cfg.enable {
    system.activationScripts.nxmaticEtcBackup = {
      deps = [ "specialfs" ];
      supportsDryActivation = false;
      text = ''
        set -eu

        while IFS= read -r relpath; do
          if [ -z "$relpath" ]; then
            continue
          fi

          target="/etc/$relpath"
          backup="$target.${cfg.extension}"

          if [ ! -e "$target" ] && [ ! -L "$target" ]; then
            continue
          fi

          if [ -L "$target" ]; then
            resolved="$(readlink "$target" || true)"
            case "$resolved" in
              /nix/store/*)
                continue
                ;;
            esac
          fi

          mkdir -p "$(dirname "$backup")"

          if [ -e "$backup" ] || [ -L "$backup" ]; then
            if ${lib.boolToString cfg.overwrite}; then
              rm -rf "$backup"
            else
              continue
            fi
          fi

          cp -a "$target" "$backup"
        done <<'EOF'
        ${etcTargetsLines}
        EOF
      '';
    };
  };
}