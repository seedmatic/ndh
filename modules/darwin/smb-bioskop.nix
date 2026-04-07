{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  cfg = config.services.bioskopSmbMount;
  loggerScript = config.nixBashLogger.script;
  mapFile = "/etc/auto_bioskop";
  autoMaster = "/etc/auto_master";
  bioskopFstabScript = pkgs.replaceVars ./smb-bioskop.d/fstab.sh {
    fstabEnable = lib.toString cfg.fstab.enable;
    username = cfg.username;
    host = cfg.host;
    share = cfg.share;
    mountPoint = cfg.fstab.mountPoint;
    options = cfg.fstab.options;
  };
  bioskopPostActivation = ndh.store.runCommand "bioskop-smb-post-activation.sh" { } ''
    cp ${
      pkgs.replaceVars ./smb-bioskop.d/post-activation.sh {
        inherit bioskopFstabScript;
        logger = loggerScript;
      }
    } "$out"
    chmod +x "$out"
  '';
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
    system.activationScripts.etc.text = lib.mkAfter ''
      ${bioskopPostActivation}
    '';
  };
}
