{ lib, pkgs, config, ... }:

let
  cfg = config.sharedOpenssh;
  inherit (lib) mkOption mkEnableOption types mkIf;
  # Build the base settings attrset (filter nulls)
  baseSettings =
    let raw = {
      HostKey = cfg.hostKeyPath;
      HostCertificate = cfg.hostCertPath;
      TrustedUserCAKeys = cfg.trustedCAPath;
      AuthorizedPrincipalsFile = if cfg.enablePrincipalsFile then cfg.principalsFilePath else null;
      AuthorizedPrincipalsCommand = if cfg.principalsCommand != null then "${cfg.principalsCommand} %u" else null;
      AuthorizedPrincipalsCommandUser = if cfg.principalsCommand != null then cfg.principalsCommandUser else null;
      PasswordAuthentication = false;
      PermitRootLogin = "no"; # NixOS allows string as enum ("no"), keep as is
      AuthorizedKeysFile = if cfg.enableGroupKeys then "%h/.ssh/authorized_keys ${cfg.groupAuthorizedKeysPattern}" else null;
      AuthorizedKeysCommand = if cfg.enableGroupKeys then cfg.groupAuthorizedKeysCommand else null;
      AuthorizedKeysCommandUser = if cfg.enableGroupKeys then cfg.groupAuthorizedKeysCommandUser else null;
    } // cfg.extraSettings;
    in lib.filterAttrs (_: v: v != null && v != "") raw;
in {
  options.sharedOpenssh = {
    enable = mkEnableOption "Enable shared OpenSSH baseline settings used by both Darwin and NixOS.";

    hostKeyPath = mkOption {
      type = types.str; # runtime path (e.g., /etc/ssh/ssh_host_ed25519_key)
      description = "Path to the private host key (runtime filesystem path).";
    };

    hostCertPath = mkOption {
      type = types.nullOr types.str; # may be runtime path
      default = null;
      description = "Optional host certificate path (OpenSSH -h signed host key).";
    };

    trustedCAPath = mkOption {
      type = types.nullOr types.str; # runtime path
      default = null;
      description = "Single TrustedUserCAKeys file path (no concatenation needed).";
    };

    principalsCommand = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Script that outputs valid principals; appended with %u automatically.";
    };

    principalsCommandUser = mkOption {
      type = types.str;
      default = "nobody";
      description = "User to run AuthorizedPrincipalsCommand as (ignored if command null).";
    };

    extraSettings = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Additional raw sshd_config key/value pairs (strings).";
    };
    enableGroupKeys = mkOption {
      type = types.bool;
      default = false;
      description = "Enable group-based AuthorizedKeysCommand & extended AuthorizedKeysFile pattern.";
    };
    groupAuthorizedKeysPattern = mkOption {
      type = types.str;
      default = "/etc/ssh/authorized_keys.d/%u";
      description = "Pattern appended to AuthorizedKeysFile when group keys enabled.";
    };
    groupAuthorizedKeysCommand = mkOption {
      type = types.str;
      default = "/etc/ssh/ssh-group-authorized-keys %u";
      description = "AuthorizedKeysCommand executed when group keys enabled (must include %u placeholder).";
    };
    groupAuthorizedKeysCommandUser = mkOption {
      type = types.str;
      default = "nobody";
      description = "User for AuthorizedKeysCommand when group keys enabled.";
    };
    enablePrincipalsFile = mkOption {
      type = types.bool;
      default = true;
      description = "Emit AuthorizedPrincipalsFile directive (paired with principalsFilePath).";
    };
    principalsFilePath = mkOption {
      type = types.str;
      default = "%h/.ssh/authorized_principals";
      description = "Path used for AuthorizedPrincipalsFile when enablePrincipalsFile = true.";
    };
    # Exposed computed settings (read-only) to be consumed by platform-specific modules
    settings = mkOption {
      type = types.attrsOf types.anything;
      internal = true;
      default = {};
      description = "Computed sshd settings (mixed types allowed: bool, str).";
    };
  };

  config = mkIf cfg.enable {
    # Expose computed settings for importing modules
    sharedOpenssh.settings = baseSettings;
  };
}
