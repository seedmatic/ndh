# Shared sops-nix defaults for Darwin and NixOS hosts (@codebase)
{
  config,
  lib,
  pkgs,
  ndh,
  ...
}:
let
  inherit (lib)
    mkOption
    types
    ;
  ndhContext = ndh.context;
  cfg = config.ndh.sopsAgeKeyBootstrap;
  secretNamespaceDir = "/run/secrets/nix-darwin-home";
  sshKeysSopsFile = ../../modules/home-manager/ssh.d/keys.yaml;
  sshKeysSopsContent = builtins.readFile sshKeysSopsFile;
  sshKeysSourceLooksEncrypted =
    lib.hasInfix "sops:" sshKeysSopsContent
    && !(lib.hasInfix "BEGIN OPENSSH PRIVATE KEY" sshKeysSopsContent);

  effectiveHostProfile = ndhContext.hostProfile;
  effectiveGenerationMode = ndhContext.generationMode;
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

  nixosbringupMode = effectiveGenerationMode == "bringup";

  vmProvider =
    if config ? ndh && config.ndh ? vm && config.ndh.vm ? provider then
      config.ndh.vm.provider
    else if effectiveHostProfile ? vmProvider && effectiveHostProfile.vmProvider != null then
      effectiveHostProfile.vmProvider
    else
      "lima";

  hostSopsKeyShareMountPoint =
    if vmProvider == "tart" then
      lib.attrByPath [
        "ndh"
        "vm"
        "tart"
        "hostShares"
        "sopsAge"
        "mountPoint"
      ] "/srv/host/sops.d" config
    else
      "/mnt/lima-cidata/sops.d";

  nixosHostKeyImportCandidatesDefault = lib.filter (path: path != "") [
    "${userHome}/.config/sops/age/keys.txt"
    (if userName != "" then "/home/${userName}/.config/sops/age/keys.txt" else "")
    "${hostSopsKeyShareMountPoint}/age/keys.txt"
  ];

  trampolineDir = pkgs.runCommand "io.nxmatic.nix-darwin-home-trampoline-dir" { } ''
    mkdir -p "$out"
    install -m 0644 ${./shell.d/logger.sh} "$out/logger.sh"
    install -m 0755 ${./shell.d/nix-bash-trampoline.sh} "$out/nix-bash-trampoline.sh"
  '';
  sopsAgeBootstrapScript =
    builtins.replaceStrings
      [
        "@nixBashTrampoline@"
        "@keyFile@"
        "@publicKeyFile@"
        "@exportPublicKeyOnActivation@"
        "@nixosImportFromHost@"
        "@remoteFetchEnable@"
        "@remoteFetchUser@"
        "@remoteFetchKeyPath@"
        "@remoteFetchUseSudo@"
        "@remoteFetchHostnameEnvVar@"
        "@remoteFetchMdnsSuffix@"
        "@phase@"
        "@darwinUserKeyFile@"
        "@importExistingUserKeyOnBootstrap@"
        "@nixosHostKeyImportCandidates@"
      ]
      [
        "${trampolineDir}/nix-bash-trampoline.sh"
        (toString config.sops.age.keyFile)
        (toString cfg.publicKeyFile)
        (if cfg.exportPublicKeyOnActivation then "1" else "0")
        (if cfg.nixosHostKeyImport.enable then "1" else "0")
        (if cfg.nixosHostKeyImport.remoteFetch.enable then "1" else "0")
        (toString cfg.nixosHostKeyImport.remoteFetch.user)
        (toString cfg.nixosHostKeyImport.remoteFetch.keyPath)
        (if cfg.nixosHostKeyImport.remoteFetch.useSudo then "1" else "0")
        (toString cfg.nixosHostKeyImport.remoteFetch.hostnameEnvVar)
        (toString cfg.nixosHostKeyImport.remoteFetch.mdnsSuffix)
        (toString cfg.phase)
        (toString cfg.darwinUserKeyFile)
        (if cfg.importExistingUserKeyOnBootstrap then "1" else "0")
        (lib.concatStringsSep "\n" cfg.nixosHostKeyImport.candidates)
      ]
      (builtins.readFile ./sops.d/bootstrap.sh);
  sopsAgeBootstrapSystemdScript =
    ndh.store.runCommand "sops-age-bootstrap"
      {
        passAsFile = [ "text" ];
        text = sopsAgeBootstrapScript;
      }
      ''
        {
          printf '%s\n' '#!${pkgs.bash}/bin/bash'
          cat "$textPath"
        } > "$out"
        chmod 0555 "$out"
      '';
  useSystemdSopsActivation = config.sops.useSystemdActivation or false;
  namespaceSecretPaths =
    let
      secretAttrs = config.sops.secrets or { };
      allPaths = lib.mapAttrsToList (_name: secret: toString (secret.path or "")) secretAttrs;
    in
    lib.filter (path: path != "" && lib.hasPrefix "${secretNamespaceDir}/" path) allPaths;
  forbiddenSshLikeNamespacePaths = lib.filter (
    path:
    path != "${secretNamespaceDir}/ssh-keys.yaml"
    && builtins.match ".*(ssh|key).*" (builtins.baseNameOf path) != null
  ) namespaceSecretPaths;
in
{
  options.ndh.sopsAgeKeyBootstrap = {
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

    defaultAgeKeyFile = mkOption {
      type = types.str;
      default = cfg.systemWideKeyFile;
      description = ''
        Canonical default for `sops.age.keyFile`.
        Platform modules should set this via `mkDefault`.
      '';
    };

    sudoCommand = mkOption {
      type = types.str;
      default = "${pkgs.sudo}/bin/sudo";
      description = ''
        Absolute sudo command used by SOPS age key bootstrap helper logic.
        Platform modules may override (for example Darwin `/usr/bin/sudo`).
      '';
    };

    systemdUnitName = mkOption {
      type = types.str;
      default = "sops-age-bootstrap";
      description = "NixOS systemd unit name used for SOPS age bootstrap ordering.";
    };

    systemdExecStartScript = mkOption {
      type = types.path;
      readOnly = true;
      default = sopsAgeBootstrapSystemdScript;
      description = "Store path of the generated bootstrap script for systemd ExecStart in NixOS modules.";
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
      default = "/etc/sops/age/keys.pub";
      description = ''
        Path where the host public age recipient is published.
        This file is safe to collect into `.sops.yaml` recipient groups.
      '';
    };

    nixosHostKeyImport = {
      enable = mkOption {
        type = types.bool;
        default = false;
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
          default = false;
          description = ''
            Enable best-effort remote key fetch over SSH before local candidate file checks.
            Hostname is resolved from `hostnameEnvVar` (e.g. `NDH_VZ_HOST`) and mDNS suffix.
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
          default = "NDH_VZ_HOST";
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

      secrets = {
        "ssh-keys.yaml" = {
          sopsFile = sshKeysSopsFile;
          format = "yaml";
          # Emit the full decrypted YAML document; profile selection happens at runtime.
          key = "";
          path = "${secretNamespaceDir}/ssh-keys.yaml";
          owner = config.profile.user.name;
          mode = "0400";
        };
      };

      age.keyFile = lib.mkDefault cfg.defaultAgeKeyFile;
      # In first-boot bootstrap images, avoid host SSH-key based decryption fallback.
      # Host keys may not exist yet at the point sops-install-secrets is executed.
      age.sshKeyPaths = lib.mkIf nixosbringupMode [ ];

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
      {
        assertion = forbiddenSshLikeNamespacePaths == [ ];
        message = ''
          /run/secrets/nix-darwin-home SSH/key policy violation:
          only ${secretNamespaceDir}/ssh-keys.yaml is allowed for SSH/key-like secret names in this namespace.
          Forbidden paths: ${lib.concatStringsSep ", " forbiddenSshLikeNamespacePaths}
        '';
      }
    ];

    # Two-phase age-key bootstrap guard:
    # phase=bootstrap provisions once, phase=enforce blocks activation when missing.
    system.activationScripts.preActivation.text = lib.mkBefore (
      if !useSystemdSopsActivation then sopsAgeBootstrapScript else ""
    );

  };
}
