{
  lib,
  config,
  pkgs,
  ndh,
  self,
  ...
}:
let
  cfg = config.opensshPolicy;
  inherit (lib)
    mkOption
    mkEnableOption
    types
    mkIf
    mkMerge
    mkDefault
    mkForce
    ;
  # Build settings attrset.
  # Notes:
  #  - We DO NOT inject multiple HostKey directives here because an attrset
  #    would collapse duplicate keys. Instead we expose hostKeyPaths (and
  #    an internal helper hostKeys), which platform modules render as HostKey
  #    lines. Not services.openssh.hostKeys on NixOS: it also generates the keys.
  #  - On Darwin we auto-fold authorizedKeysFiles into a single space-separated
  #    AuthorizedKeysFile directive (OpenSSH accepts a list written as a single line).
  baseSettings =
    let
      raw = {
        PasswordAuthentication = cfg.passwordAuthentication;
        # Through PAM, keyboard-interactive asks for the same password; both default to
        # yes (NixOS, macOS), so turning only the first off leaves password login open.
        KbdInteractiveAuthentication = cfg.passwordAuthentication;
        PermitRootLogin = cfg.permitRootLogin;
        TrustedUserCAKeys = cfg.trustedCAPath;
        RevokedKeys = cfg.revokedKeysPath;
        AuthorizedPrincipalsFile = cfg.principalsFilePath;
        AuthorizedPrincipalsCommand =
          if cfg.principalsCommandSource != null then
            "${cfg.canonicalCommandDir}/${cfg.canonicalPrincipalsCommandName} %u"
          else
            null;
        AuthorizedPrincipalsCommandUser =
          if cfg.principalsCommandSource != null then cfg.principalsCommandUser else null;
        # Group keys command directives (only if enabled)
        AuthorizedKeysCommand =
          if cfg.groupKeysCommandSource != null then
            "${cfg.canonicalCommandDir}/${cfg.canonicalGroupKeysCommandName} %u"
          else
            null;
        AuthorizedKeysCommandUser =
          if cfg.groupKeysCommandSource != null then cfg.groupCommandUser else null;
        # Platform-specific render toggle for AuthorizedKeysFile list.
        AuthorizedKeysFile =
          if cfg.platformRendersAuthorizedKeysFile then
            lib.concatStringsSep " " cfg.authorizedKeysFiles
          else
            null;
        # Allow user environment file by default on both platforms
        PermitUserEnvironment = "yes";
        # Baseline PATH for sshd sessions and ensure non-interactive bash sources our file
        # Note: SetEnv accepts space-separated VAR=VALUE pairs.
        SetEnv = "PATH=${cfg.setEnvPath} BASH_ENV=/etc/profile.d/noninteractive.sh";
      }
      // cfg.extraSettings;
    in
    lib.filterAttrs (_: v: v != null && v != "") raw;
in
{
  imports = [
    ./ssh-paths.nix
    ./host-key.nix
  ];

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

    # ssh matches a Host line against the name given, never against its HostName, so an alias to a fleet
    # machine is strict only when it is listed itself. Filled by the module that defines the alias.
    fleetHostAliases = mkOption {
      type = types.listOf types.str;
      default = [ ];
      description = "Aliases whose HostName is a fleet name, checked as strictly as the fleet's names.";
    };

    trustedCAPath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Path to TrustedUserCAKeys file (system-readable, e.g. `\${sshPaths.systemKeysDir}/trusted-user-ca.pub`).";
    };

    revokedKeysPath = mkOption {
      type = types.str;
      default = "${config.ndh.keysYaml.krlFile}";
      description = ''
        RevokedKeys file. Defaults to the KRL built from keys.yaml's `.revoked`
        and `.revoked_certificates` — see ndh.keysYaml.krlFile for why it is not a
        runtime file.
      '';
    };

    # Principals file. `none`: sshd accepts a principal found in the file OR in the
    # command's output, so a file in the user's home would let any process running as
    # that user widen what the command decides. The command alone decides.
    principalsFilePath = mkOption {
      type = types.str;
      default = "none";
      description = "AuthorizedPrincipalsFile path; `none` leaves AuthorizedPrincipalsCommand alone.";
    };

    # Principals command
    principalsCommandSource = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Store path (or derivation) of principals command script to be installed at canonical runtime path.";
    };
    principalsCommandUser = mkOption {
      type = types.str;
      default = "nobody";
      description = "Run AuthorizedPrincipalsCommand as this user.";
    };

    # Group keys aggregation
    authorizedKeysDir = mkOption {
      type = types.str;
      default = "/etc/ssh/nix_authorized_keys.d";
      description = "Directory containing authorized keys files (both user and group-based).";
    };
    groupKeysCommandSource = mkOption {
      type = types.nullOr types.path;
      default = null;
      description = "Store path (or derivation) of group authorized keys aggregation script to be installed at canonical runtime path.";
    };
    groupCommandUser = mkOption {
      type = types.str;
      default = "nobody";
      description = "User to run group AuthorizedKeysCommand as.";
    };

    authorizedKeysFiles = mkOption {
      type = types.listOf types.str;
      default = [
        "%h/.ssh/authorized_keys"
        "${cfg.authorizedKeysDir}/%u" # unified user/group keys location
      ];
      description = "List used to populate AuthorizedKeysFile (NixOS native option or rendered on Darwin).";
    };

    canonicalCommandDir = mkOption {
      type = types.str;
      default = "/etc/ssh";
      description = "Directory into which canonical command scripts are installed.";
    };
    keysDir = mkOption {
      type = types.str;
      default = config.sshPaths.systemKeysDir;
      description = ''
        Directory where OpenSSH-related keys (builder, CA aggregate) are
        stored. Defaults to `sshPaths.systemKeysDir` so sshd reads the
        same root-owned directory where the ssh-keys enrichment pipeline
        materializes authority pubs + certs — no intermediate mirror
        under `/etc/ssh/keys.d` required.
      '';
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

    # Shared drop-in include globs for both platforms; rendered appropriately per OS
    includeDaemonGlobs = mkOption {
      type = types.listOf types.str;
      default = [ "sshd_config.d/*.conf" ];
      description = "Glob(s) included by sshd_config via Include lines (relative to /etc/ssh).";
    };
    includeClientGlobs = mkOption {
      type = types.listOf types.str;
      default = [
        "ssh_config.d/*.conf"
        "/etc/ssh/ssh_config.d/*.conf"
      ];
      description = "Glob(s) included by ssh client config via Include lines (relative to /etc/ssh). Include both relative and absolute forms for compatibility.";
    };

    # Shared PATH used by sshd SetEnv (override per-host if needed)
    setEnvPath = mkOption {
      type = types.str;
      default = "/run/wrappers/bin:/run/current-system/sw/bin:/bin:/usr/bin";
      description = "PATH value applied via sshd SetEnv for non-interactive SSH sessions.";
    };

    nonInteractivePrimaryPath = mkOption {
      type = types.str;
      default = "/run/wrappers/bin";
      description = "Primary PATH prefix enforced for non-interactive sshd-launched shells.";
    };

    platformRendersAuthorizedKeysFile = mkOption {
      type = types.bool;
      default = false;
      description = "Whether this platform renders AuthorizedKeysFile from opensshPolicy.authorizedKeysFiles.";
    };

    # Host keys / certificate (optional referencing existing files). Not enforced; left for completeness.
    hostCertificatePath = mkOption {
      type = types.nullOr types.str;
      default = null;
      description = "Optional HostCertificate path.";
    };
    hostKeyPaths = mkOption {
      type = types.listOf types.str;
      default = [ ]; # If empty we don't inject HostKey lines; rely on system defaults
      description = "Explicit host key files to add (in order).";
    };

    extraSettings = mkOption {
      type = types.attrsOf types.str;
      default = { };
      description = "Additional raw sshd_config key/value pairs.";
    };

    # Exposed computed settings
    settings = mkOption {
      internal = true;
      type = types.attrsOf types.anything;
      default = { };
      description = "Computed sshd settings attrset.";
    };
    # Helper: expose host keys list (not injected into settings to avoid duplicate key collapse)
    hostKeys = mkOption {
      internal = true;
      type = types.listOf types.str;
      default = [ ];
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
      let
        cert =
          if cfg.hostCertificatePath != null then { HostCertificate = cfg.hostCertificatePath; } else { };
      in
      cert // baseSettings;
    # Host verification by the AUTHORITY, system-wide — /etc/ssh/ssh_known_hosts,
    # read by every user including root. KnownHostsCommand (home-manager) only
    # covers the operator, so root's connections — the sshfs mounts, nix-daemon to
    # its builders, the guest sops bootstrap — verified hosts by raw keys pinned
    # on first use, and a host-key renewal breaks a pin: `accept-new` accepts an
    # UNKNOWN host, never a CHANGED one. Measured on a throwaway sshd: with the
    # authority here, a certificate-presenting host is accepted even past a stale
    # raw pin, so the existing pins need no cleanup. One entry per TRUSTED slot, so
    # both generations are trusted while the authority itself renews, and a slot
    # marked `compromised` is not (ndh.keysYaml.trustedAuthoritySlots). For the
    # fleet's names only, never `*`: under `*`, a host certificate the authority
    # signed would be accepted for any host, the corporate bare-metal or GitHub included.
    programs.ssh.knownHosts = lib.listToAttrs (
      lib.concatLists (
        lib.mapAttrsToList (
          name: authority:
          lib.optionals (lib.elem "ssh-authority" (authority.usage or [ ])) (
            lib.mapAttrsToList
              (slot: material: {
                name = "${name}@${slot}";
                value = {
                  certAuthority = true;
                  hostNames = self.fleetHostNames;
                  publicKey = "${authority.type or "ssh-ed25519"} ${material.public}";
                };
              })
              (
                lib.filterAttrs (_slot: material: (material.public or "") != "") (
                  config.ndh.keysYaml.trustedAuthoritySlots.${name} or { }
                )
              )
          )
        ) config.ndh.keysYaml.authorities
      )
    );
    # Revocation on the CLIENT side, from the list sshd's RevokedKeys already reads: every client, root
    # included (nix-daemon's remote builds, the sshfs mounts, the vzhost deploy), refuses a host key in
    # keys.yaml `revoked`, a certificate whose signing authority is there, and a certificate
    # `revoked_certificates` names by its key id. Host certificates are valid forever by decision (a
    # missed calendar renewal would break every strict connection), so this is what cuts a leaked host
    # key: at the next activation, not at an expiry. First, before any Host line: ssh keeps the first
    # value it obtains, and under a Host stanza the line would bind that host only.
    programs.ssh.extraConfig = lib.mkBefore "RevokedHostKeys ${config.ndh.keysYaml.krlFile}\n";
    # The fleet's names and the aliases to them are trusted through the authority ONLY, for root as for the
    # operator (the operator's decision, 2026-10-17): no raw key is ever pinned for them, so a host without a
    # valid, unrevoked certificate is refused, and a host key change needs no known_hosts upkeep.
    # A drop-in, read before every `Host *` default: in the main file this stanza would also capture
    # the Include lines after it, an Include under a Host line being conditional on that host.
    environment.etc."ssh/ssh_config.d/10-fleet-hosts.conf".text = ''
      Host ${lib.concatStringsSep " " (lib.unique (self.fleetHostNames ++ cfg.fleetHostAliases))}
        StrictHostKeyChecking yes
        UserKnownHostsFile /dev/null
        UpdateHostKeys no
    '';

    # Expose helpers
    opensshPolicy.hostKeys = cfg.hostKeyPaths;
    opensshPolicy.authorizedKeysFileString =
      if cfg.platformRendersAuthorizedKeysFile then
        lib.concatStringsSep " " cfg.authorizedKeysFiles
      else
        null;

    # Ensure non-interactive `/bin/bash -c` launched by sshd gets a canonical
    # PATH immediately, with a platform-appropriate primary prefix.
    environment.etc."profile.d/noninteractive.sh".source = ndh.store.writeText "noninteractive.sh" ''
      #!/bin/sh
      # Only modify PATH for non-interactive shells (bash -c; $- lacks 'i')
      case "$-" in
        *i*) : ;;
        *)
          PRIMARY="${cfg.nonInteractivePrimaryPath}"
          # Fallback PATH if empty (literal, no Nix interpolation)
          if [ -z "$PATH" ]; then
            PATH="${cfg.setEnvPath}"
          fi
          first="$(printf %s "$PATH" | cut -d: -f1)"
          if [ "$first" != "$PRIMARY" ] && [ -d "$PRIMARY" ]; then
            PATH="$PRIMARY:$PATH"
            export PATH
          fi
          ;;
      esac
    '';
  };
}
