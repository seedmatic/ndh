{ lib, config, pkgs, ... }:
let
  cfg = config.opensshPolicy;
  inherit (lib) mkOption mkEnableOption types mkIf mkMerge mkDefault mkForce;
  # Build settings attrset.
  # Notes:
  #  - We DO NOT inject multiple HostKey directives here because an attrset
  #    would collapse duplicate keys. Instead we expose hostKeyPaths (and
  #    an internal helper hostKeys) and expect platform modules to map them
  #    to their native options (e.g. services.openssh.hostKeys on NixOS) or
  #    render lines explicitly on Darwin if desired.
  #  - On Darwin we auto-fold authorizedKeysFiles into a single space-separated
  #    AuthorizedKeysFile directive (OpenSSH accepts a list written as a single line).
  baseSettings =
    let raw = {
      PasswordAuthentication = cfg.passwordAuthentication;
      PermitRootLogin = cfg.permitRootLogin;
      TrustedUserCAKeys = cfg.trustedCAPath;
      AuthorizedPrincipalsFile = cfg.principalsFilePath;
      AuthorizedPrincipalsCommand =
        if cfg.principalsCommandSource != null then "${cfg.canonicalCommandDir}/${cfg.canonicalPrincipalsCommandName} %u"
        else if cfg.principalsCommandScript != null then "${cfg.principalsCommandScript} %u"
        else null;
      AuthorizedPrincipalsCommandUser =
        if (cfg.principalsCommandSource != null) || (cfg.principalsCommandScript != null) then cfg.principalsCommandUser else null;
      # Group keys command directives (only if enabled)
      AuthorizedKeysCommand =
        if cfg.groupKeysCommandSource != null then "${cfg.canonicalCommandDir}/${cfg.canonicalGroupKeysCommandName} %u"
        else if cfg.groupCommand != null && cfg.groupCommand != "" then cfg.groupCommand else null;
      AuthorizedKeysCommandUser =
        if (cfg.groupKeysCommandSource != null) || (cfg.groupCommand != null && cfg.groupCommand != "") then cfg.groupCommandUser else null;
      # Darwin auto-fold of AuthorizedKeysFile list; on NixOS we rely on native list option
      AuthorizedKeysFile = if pkgs.stdenv.isDarwin then lib.concatStringsSep " " cfg.authorizedKeysFiles else null;
    } // cfg.extraSettings;
    in lib.filterAttrs (_: v: v != null && v != "") raw;
in {
  options.opensshPolicy = {
    enable = mkEnableOption "Unified OpenSSH policy (NixOS + Darwin).";

    passwordAuthentication = mkOption {
      type = types.bool;
      default = false;
      description = "Whether to allow password authentication.";
    };

    permitRootLogin = mkOption {
      type = types.str; # Accept OpenSSH values: "no", "prohibit-password", etc.
      default = "no";
      description = "PermitRootLogin directive value.";
    };

    trustedCAPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to TrustedUserCAKeys file.";
    };

    # Principals file
    principalsFilePath = mkOption {
      type = types.str;
      default = "%h/.ssh/authorized_principals";
      description = "AuthorizedPrincipalsFile path.";
    };

    # Principals command
      principalsCommandScript = mkOption {
        # Use string instead of path so runtime absolute paths like /etc/ssh/authorized-principals-command
        # do not trigger pure evaluation path access errors.
        type = types.nullOr types.str;
        default = null;
        description = "Script path for AuthorizedPrincipalsCommand (without %u). If non-null, directives are emitted. Accepts runtime absolute paths.";
      };
    principalsCommandSource = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Store path (or derivation) of principals command script to be installed at canonical runtime path. Takes precedence over principalsCommandScript.";
    };
    principalsCommandUser = mkOption {
      type = types.str;
      default = "nobody";
      description = "Run AuthorizedPrincipalsCommand as this user.";
    };

    # Group keys aggregation
    groupDirectory = mkOption {
      type = types.str;
      default = "/etc/ssh/authorized_keys.d";
      description = "Directory containing group authorized keys files.";
    };
    groupCommand = mkOption {
      type = types.str;
      # New unified runtime script name (old name: /etc/ssh/ssh-group-authorized-keys)
      default = "/etc/ssh/ssh-group-authorized-keys-command %u";
      description = ''AuthorizedKeysCommand for group-based keys (must include %u).
        Default changed to /etc/ssh/ssh-group-authorized-keys-command (old path kept via symlink if present).'';
    };
    groupKeysCommandSource = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Store path (or derivation) of group authorized keys aggregation script to be installed at canonical runtime path. When set, overrides groupCommand path with canonical path.";
    };
    groupCommandUser = mkOption {
      type = types.str;
      default = "nobody";
      description = "User to run group AuthorizedKeysCommand as.";
    };

    authorizedKeysFiles = mkOption {
      type = types.listOf types.str;
      default = [ "%h/.ssh/authorized_keys" "/etc/ssh/authorized_keys.d/%u" ];
      description = "List used to populate AuthorizedKeysFile (NixOS native option or rendered on Darwin).";
    };

    canonicalCommandDir = mkOption {
      type = types.str;
      default = "/etc/ssh";
      description = "Directory into which canonical command scripts are installed.";
    };
    canonicalPrincipalsCommandName = mkOption {
      type = types.str;
      default = "ssh-authorized-principals-command";
      description = "Basename for principals command script when using principalsCommandSource.";
    };
    canonicalGroupKeysCommandName = mkOption {
      type = types.str;
      default = "ssh-group-authorized-keys-command";
      description = "Basename for group keys command script when using groupKeysCommandSource.";
    };

    cleanupLegacyCommandScripts = mkOption {
      type = types.bool;
      default = true;
      description = "Whether activation should attempt to replace legacy command script copies with symlinks to the canonical names (safe, only when contents match).";
    };

    # Host keys / certificate (optional referencing existing files). Not enforced; left for completeness.
    hostCertificatePath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional HostCertificate path.";
    };
    hostKeyPaths = mkOption {
      type = types.listOf types.str;
      default = []; # If empty we don't inject HostKey lines; rely on system defaults
      description = "Explicit host key files to add (in order).";
    };

    extraSettings = mkOption {
      type = types.attrsOf types.str;
      default = {};
      description = "Additional raw sshd_config key/value pairs.";
    };

    # Exposed computed settings
    settings = mkOption {
      internal = true;
      type = types.attrsOf types.anything;
      default = {};
      description = "Computed sshd settings attrset.";
    };
    # Helper: expose host keys list (not injected into settings to avoid duplicate key collapse)
    hostKeys = mkOption {
      internal = true;
      type = types.listOf types.str;
      default = [];
      description = "List of host key file paths for platform modules to consume.";
    };
    # Helper: Darwin-rendered AuthorizedKeysFile string (null on non-Darwin)
    authorizedKeysFileString = mkOption {
      internal = true;
      type = types.nullOr types.str;
      default = null;
      description = "Space-separated AuthorizedKeysFile directive string (Darwin only).";
    };
  };

  config = mkIf cfg.enable {
    # HostCertificate is singular; merge if provided.
    opensshPolicy.settings =
      let cert = if cfg.hostCertificatePath != null then { HostCertificate = cfg.hostCertificatePath; } else {}; in
      cert // baseSettings;
    # Expose helpers
    opensshPolicy.hostKeys = cfg.hostKeyPaths;
    opensshPolicy.authorizedKeysFileString = if pkgs.stdenv.isDarwin then lib.concatStringsSep " " cfg.authorizedKeysFiles else null;
  };
}
