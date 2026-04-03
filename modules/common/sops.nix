# Shared sops-nix defaults for Darwin and NixOS hosts (@codebase)
{
  config,
  lib,
  pkgs,
  hostProfile ? { },
  ...
}:
let
  inherit (lib)
    mkOption
    types
    ;
  cfg = config.nxmatic.sopsAgeKeyBootstrap;
  secretNamespaceDir = "/run/secrets/nix-darwin-home";
  sshKeysSopsFile = ../../modules/home-manager/ssh.d/keys.yaml;
  sshKeysSopsContent = builtins.readFile sshKeysSopsFile;
  sshKeysSourceLooksEncrypted =
    lib.hasInfix "sops:" sshKeysSopsContent
    && !(lib.hasInfix "BEGIN OPENSSH PRIVATE KEY" sshKeysSopsContent);

  userHome =
    if config ? profile && config.profile ? user && config.profile.user ? home then
      toString config.profile.user.home
    else
      "/var/empty";

  userName =
    if config ? profile && config.profile ? user && config.profile.user ? name then
      toString config.profile.user.name
    else
      "";

  ageKeyFileDefault =
    if pkgs.stdenv.isDarwin then
      (if cfg.darwinSystemWideKey then cfg.systemWideKeyFile else cfg.darwinUserKeyFile)
    else
      cfg.systemWideKeyFile;

  nixosBootstrapMode =
    (!pkgs.stdenv.isDarwin)
    && hostProfile ? nixosImageMode
    && hostProfile.nixosImageMode != null
    && hostProfile.nixosImageMode == "bootstrap";

  nixosHostKeyImportCandidatesDefault =
    lib.filter (path: path != "") [
      "${userHome}/.config/sops/age/keys.txt"
      (if userName != "" then "/home/${userName}/.config/sops/age/keys.txt" else "")
      (if userName != "" then "/Users/${userName}/.config/sops/age/keys.txt" else "")
      "/mnt/lima-cidata/sops-age-keys.txt"
    ];

  sopsAgeBootstrapScriptSource = pkgs.replaceVars ./sops.d/bootstrap.sh {
    keyFile = config.sops.age.keyFile;
    publicKeyFile = cfg.publicKeyFile;
    exportPublicKeyOnActivation = if cfg.exportPublicKeyOnActivation then "1" else "0";
    nixosImportFromHost = if cfg.nixosHostKeyImport.enable then "1" else "0";
    remoteFetchEnable = if cfg.nixosHostKeyImport.remoteFetch.enable then "1" else "0";
    remoteFetchUser = cfg.nixosHostKeyImport.remoteFetch.user;
    remoteFetchKeyPath = cfg.nixosHostKeyImport.remoteFetch.keyPath;
    remoteFetchUseSudo = if cfg.nixosHostKeyImport.remoteFetch.useSudo then "1" else "0";
    remoteFetchHostnameEnvVar = cfg.nixosHostKeyImport.remoteFetch.hostnameEnvVar;
    remoteFetchMdnsSuffix = cfg.nixosHostKeyImport.remoteFetch.mdnsSuffix;
    sshBin = pkgs.openssh;
    sudoCmd = if pkgs.stdenv.isDarwin then "/usr/bin/sudo" else "${pkgs.sudo}/bin/sudo";
    utilLinuxBin = pkgs.util-linux;
    phase = cfg.phase;
    darwinUserKeyFile = cfg.darwinUserKeyFile;
    importExistingUserKeyOnBootstrap = if cfg.importExistingUserKeyOnBootstrap then "1" else "0";
    ageBin = pkgs.age;
    coreutilsBin = pkgs.coreutils;
    nixosHostKeyImportCandidates = lib.concatStringsSep "\n" cfg.nixosHostKeyImport.candidates;
  };
  sopsAgeBootstrapScript = builtins.readFile sopsAgeBootstrapScriptSource;
in
{
  options.nxmatic.sopsAgeKeyBootstrap = {
    phase = mkOption {
      type = types.enum [
        "bootstrap"
        "enforce"
      ];
      default = "enforce";
      description = ''
        Two-phase SOPS age-key provisioning mode.
        - bootstrap: generate `${config.sops.age.keyFile}` on first activation if missing.
        - enforce: fail activation when `${config.sops.age.keyFile}` is missing.
      '';
    };

    darwinSystemWideKey = mkOption {
      type = types.bool;
      default = false;
      description = ''
        Darwin-only toggle to install/use a system-wide SOPS age key file.
        When enabled, `${config.sops.age.keyFile}` defaults to `systemWideKeyFile`
        instead of the per-user key path.
      '';
    };

    systemWideKeyFile = mkOption {
      type = types.str;
      default = "/etc/sops/age/keys.txt";
      description = "System-wide SOPS age key file path.";
    };

    darwinUserKeyFile = mkOption {
      type = types.str;
      default = "${userHome}/.config/sops/age/keys.txt";
      description = "Darwin user-scoped SOPS age key file path used for migration/bootstrap import.";
    };

    importExistingUserKeyOnBootstrap = mkOption {
      type = types.bool;
      default = true;
      description = ''
        During bootstrap, if `${config.sops.age.keyFile}` is missing but
        `darwinUserKeyFile` exists, copy it into the target key path before
        generating a new key.
      '';
    };

    exportPublicKeyOnActivation = mkOption {
      type = types.bool;
      default = true;
      description = ''
        Derive and publish the host public age recipient from
        `${config.sops.age.keyFile}` on each activation.
      '';
    };

    publicKeyFile = mkOption {
      type = types.str;
      default = if pkgs.stdenv.isDarwin then "/etc/sops/age/keys.pub" else "/etc/sops/age/keys.pub";
      description = ''
        Path where the host public age recipient is published.
        This file is safe to collect into `.sops.yaml` recipient groups.
      '';
    };

    nixosHostKeyImport = {
      enable = mkOption {
        type = types.bool;
        default = !pkgs.stdenv.isDarwin;
        description = ''
          Enable NixOS pre-activation import of an existing host age key into
          `${config.sops.age.keyFile}` when missing and phase is `enforce`.
          Intended for Lima/VM guests where a host-mounted path can provide key material.
        '';
      };

      candidates = mkOption {
        type = types.listOf types.str;
        default = nixosHostKeyImportCandidatesDefault;
        description = ''
          Ordered list of candidate file paths to import an existing age key from
          when `${config.sops.age.keyFile}` is missing in `enforce` mode.
        '';
      };

      remoteFetch = {
        enable = mkOption {
          type = types.bool;
          default = !pkgs.stdenv.isDarwin;
          description = ''
            Enable best-effort remote key fetch over SSH before local candidate file checks.
            Hostname is resolved from `hostnameEnvVar` (e.g. `LIMA_HOSTNAME`) and mDNS suffix.
          '';
        };

        user = mkOption {
          type = types.str;
          default = "root";
          description = ''
            Username used for SSH remote fetch. Set to `root` to avoid a user+sudo hop.
          '';
        };

        keyPath = mkOption {
          type = types.str;
          default = "/etc/sops/age/keys.txt";
          description = "Remote key path fetched over SSH when remoteFetch is enabled.";
        };

        useSudo = mkOption {
          type = types.bool;
          default = false;
          description = ''
            When true and `user` is not root, run remote key reads via `sudo -n`.
            Keep this false for root-first fetch mode.
          '';
        };

        hostnameEnvVar = mkOption {
          type = types.str;
          default = "LIMA_HOSTNAME";
          description = "Environment variable name containing the host identifier used for remote fetch.";
        };

        mdnsSuffix = mkOption {
          type = types.str;
          default = ".local";
          description = "Suffix appended when hostname from `hostnameEnvVar` has no domain part.";
        };
      };
    };
  };

  config = {
    sops = {
      # Canonical encrypted secrets source tracked in this repository.
      defaultSopsFile = lib.mkDefault ../../.secrets;

      secrets = lib.mkIf (!nixosBootstrapMode) {
        "nxmatic-ssh-keys.yaml" = {
          sopsFile = sshKeysSopsFile;
          format = "yaml";
          # Emit the full decrypted YAML document; profile selection happens at runtime.
          key = "";
          path = "${secretNamespaceDir}/nxmatic-ssh-keys.yaml";
          owner = config.profile.user.name;
          mode = "0400";
        };
      };

      age.keyFile = lib.mkDefault ageKeyFileDefault;
      # In first-boot bootstrap images, avoid host SSH-key based decryption fallback.
      # Host keys may not exist yet at the point sops-install-secrets is executed.
      age.sshKeyPaths = lib.mkIf nixosBootstrapMode [ ];

    };

    assertions = [
      {
        assertion = sshKeysSourceLooksEncrypted;
        message = ''
          sops source-of-truth violation: modules/home-manager/ssh.d/keys.yaml appears decrypted in this worktree.
          Refusing evaluation to prevent accidental plaintext secret ingestion into the Nix store.
          Re-encrypt the file with sops before rebuild.
        '';
      }
    ];

    # Two-phase age-key bootstrap guard:
    # phase=bootstrap provisions once, phase=enforce blocks activation when missing.
    # Use preActivation to guarantee key material exists before sops-install-secrets runs.
    system.activationScripts.preActivation.text = lib.mkBefore sopsAgeBootstrapScript;
  };
}
