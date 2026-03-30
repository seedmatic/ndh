# Shared sops-nix defaults for Darwin and NixOS hosts (@codebase)
{
  config,
  lib,
  pkgs,
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

  ageKeyFileDefault =
    if pkgs.stdenv.isDarwin then
      (if cfg.darwinSystemWideKey then cfg.systemWideKeyFile else cfg.darwinUserKeyFile)
    else
      cfg.systemWideKeyFile;

  sopsAgeBootstrapScript =
    ''
      set -eu

      key_file="${config.sops.age.keyFile}"
      public_key_file="${cfg.publicKeyFile}"
      public_key_dir="$(dirname "$public_key_file")"
      export_public_key_on_activation="${if cfg.exportPublicKeyOnActivation then "1" else "0"}"
    ''
    + (if cfg.phase == "bootstrap" then
        ''
          key_dir="$(dirname "$key_file")"
          darwin_user_key_file="${cfg.darwinUserKeyFile}"
          import_existing_user_key_on_bootstrap="${if cfg.importExistingUserKeyOnBootstrap then "1" else "0"}"

          if [ ! -s "$key_file" ]; then
            install -d -m 700 "$key_dir"
            if [ "$import_existing_user_key_on_bootstrap" = "1" ] && [ "$darwin_user_key_file" != "$key_file" ] && [ -s "$darwin_user_key_file" ]; then
              cp "$darwin_user_key_file" "$key_file"
              chmod 600 "$key_file"
              echo "[sops-age-bootstrap] installed existing user age key into $key_file"
            else
              ${pkgs.age}/bin/age-keygen -o "$key_file"
              chmod 600 "$key_file"
              echo "[sops-age-bootstrap] generated age key at $key_file"
            fi
          else
            echo "[sops-age-bootstrap] existing age key detected at $key_file"
          fi
        ''
      else
        ''
          if [ ! -s "$key_file" ]; then
            echo "[sops-age-bootstrap] ERROR: missing SOPS age key at $key_file"
            echo "[sops-age-bootstrap] either provision the key manually or run one activation with nxmatic.sopsAgeKeyBootstrap.phase=\"bootstrap\""
            exit 1
          fi
        '')
    + ''
      if [ "$export_public_key_on_activation" = "1" ] && [ -s "$key_file" ]; then
        install -d -m 755 "$public_key_dir"
        ${pkgs.age}/bin/age-keygen -y "$key_file" > "$public_key_file"
        chmod 644 "$public_key_file"
        echo "[sops-age-bootstrap] published host age recipient to $public_key_file"
      fi
    '';
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
      default =
        if pkgs.stdenv.isDarwin then
          "/etc/sops/age/keys.pub"
        else
          "/etc/sops/age/keys.pub";
      description = ''
        Path where the host public age recipient is published.
        This file is safe to collect into `.sops.yaml` recipient groups.
      '';
    };
  };

  config = {
    sops = {
      # Canonical encrypted secrets source tracked in this repository.
      defaultSopsFile = lib.mkDefault ../../.secrets;

      secrets."nxmatic-ssh-keys.yaml" = {
        sopsFile = sshKeysSopsFile;
        format = "yaml";
        # Emit the full decrypted YAML document; profile selection happens at runtime.
        key = "";
        path = "${secretNamespaceDir}/nxmatic-ssh-keys.yaml";
        owner = config.profile.user.name;
        mode = "0400";
      };

      age.keyFile = lib.mkDefault ageKeyFileDefault;

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
