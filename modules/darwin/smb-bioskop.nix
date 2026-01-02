{ config, lib, ... }:
let
  cfg = config.services.bioskopSmbMount;
  mapFile = "/etc/auto_bioskop";
  autoMaster = "/etc/auto_master";
in
{
  options.services.bioskopSmbMount = {
    enable = lib.mkOption {
      type = lib.types.bool;
      default = false;
      description = "Enable SMB autofs mount for bioskop Macintosh HD share.";
    };

    username = lib.mkOption {
      type = lib.types.str;
      default = "nxmatic";
      description = "Username for SMB auth (password fetched from macOS Keychain).";
    };

    host = lib.mkOption {
      type = lib.types.str;
      default = "bioskop._smb._tcp.local";
      description = "SMB server hostname (LAN or Tailnet).";
    };

    share = lib.mkOption {
      type = lib.types.str;
      default = "Macintosh%20HD";
      description = "SMB share name (URL-escaped if needed).";
    };

    fstab = {
      enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "Also publish the share under /Network/Servers via /etc/fstab (autofs -fstab map).";
      };
      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/Network/Servers";
        description = "Mount point used for the /etc/fstab entry (ignored when using net option; autofs triggers under /Network/Servers/<host>/<share>).";
      };
      options = lib.mkOption {
        type = lib.types.str;
        default = "automounted,nobrowse,noowners,net";
        description = "Comma-separated mount options for the /etc/fstab entry. Include 'net' so autofs places trigger under /Network/Servers/<host>/<share>.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    # Configure mount via /etc/fstab at /Network/Servers (autofs -fstab map)
    system.activationScripts.bioskopSmbMount.text = ''
      set -euo pipefail

      log() { printf '[bioskop-smb] %s\n' "$1"; }

      if [ "${lib.toString cfg.fstab.enable}" = "true" ]; then
        fstab_line="//${cfg.username}@${cfg.host}/${cfg.share} ${cfg.fstab.mountPoint} url ${cfg.fstab.options},nosuid"
        log "ensuring ${cfg.fstab.mountPoint} exists"
        install -d -m 0755 "${cfg.fstab.mountPoint}"
        if ! grep -q "^//${cfg.username}@${cfg.host}/${cfg.share} ${cfg.fstab.mountPoint} " /etc/fstab 2>/dev/null; then
          log "adding fstab entry for bioskop SMB"
          printf '%s\n' "$fstab_line" | /usr/bin/tee -a /etc/fstab >/dev/null
        else
          log "fstab entry already present"
        fi
      fi
    '';
  };
}
