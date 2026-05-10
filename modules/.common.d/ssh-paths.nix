{
  lib,
  config,
  ...
}:
let
  profileFromSpecialArgs = lib.attrByPath [ "_module" "specialArgs" "profile" ] { } config;
  profile =
    if config ? profile && config.profile != null then config.profile else profileFromSpecialArgs;

  userName =
    if profile ? user && profile.user ? name && profile.user.name != null then
      profile.user.name
    else if config ? home && config.home ? username && config.home.username != null then
      config.home.username
    else
      "user";

  userHome =
    if profile ? user && profile.user ? home && profile.user.home != null then
      toString profile.user.home
    else if config ? home && config.home ? homeDirectory && config.home.homeDirectory != null then
      toString config.home.homeDirectory
    else
      "/tmp/${userName}";
in
{
  options.sshPaths = {

    # Canonical user-owned mirror of system runtime namespace.
    # On fully managed systems this can be a symlink to /var/run; on work-only
    # HM hosts it remains user-writable under $HOME.
    systemRuntimeDir = lib.mkOption {
      type = lib.types.str;
      default = "${userHome}/var/run/system";
      description = "User-scoped system runtime root used as a writable fallback for /run-backed namespaces.";
    };

    systemSecretsRootDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.systemRuntimeDir}/secrets";
      description = "User-scoped system secrets root mirroring /run/secrets layout when direct /run writes are unavailable.";
    };

    systemNamespaceDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.systemSecretsRootDir}/nix-darwin-home";
      description = "Namespace directory for nix-darwin-home secrets in system-style runtime layout.";
    };

    # Canonical per-user SSH material root. Lives under ~/.local/share so
    # it's clearly persistent, matches XDG_DATA_HOME conventions, and is
    # namespaced under the project name. The prior location,
    # ~/.local/var/run/secrets, mirrored the system /run/secrets namespace
    # and misled readers into thinking it was tmpfs-backed — it never was.
    secretsRootDir = lib.mkOption {
      type = lib.types.str;
      default = "${userHome}/.local/share/ndh";
      description = "Root directory for per-user SSH material. Persistent, user-owned.";
    };

    secretsKeysDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.secretsRootDir}/ssh-keys";
      description = "Base directory for user-owned SSH material (private identities and user-local metadata).";
    };

    authoritySecretsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.secretsRootDir}/ssh-keys/.authority.d";
      description = "Base directory for system-owned SSH material (public keys/certs/CA metadata).";
    };

    systemKeysDir = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/ndh/ssh-keys";
      description = ''
        Root-owned system directory for private identities whose top-level
        usage includes `ssh-host` (e.g. `nix-store`, `linux-builder` on
        bringup). Accessible to non-root users via `sudo`.
      '';
    };

    keyName = lib.mkOption {
      type = lib.types.str;
      default = "rdp-host";
      description = "Canonical SSH key basename used by Lima and SSH consumers.";
    };

    privKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.secretsKeysDir}/${config.sshPaths.keyName}";
      description = "Path to the SSH host private key.";
    };

    hostPublicKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.authoritySecretsDir}/${config.sshPaths.keyName}.pub";
      description = "Path to the canonical SSH host public key used by Lima and enrollment checks.";
    };

    hostCertPublic = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.authoritySecretsDir}/${config.sshPaths.keyName}-server-cert.pub";
      description = "Path to the SSH host public certificate.";
    };

    userCertPublic = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.secretsKeysDir}/${config.sshPaths.keyName}-cert.pub";
      description = "Path to the canonical SSH user certificate corresponding to privKeyFile.";
    };

    # Home-manager SSH keys workflow paths
    runtimeSecretsKeysYaml = lib.mkOption {
      type = lib.types.str;
      default =
        let
          hmSopsPath = lib.attrByPath [ "sops" "secrets" "ssh-keys.yaml" "path" ] null config;
          specialArgPath = lib.attrByPath [ "_module" "specialArgs" "sshKeysYamlPath" ] null config;
        in
        if hmSopsPath != null then
          hmSopsPath
        else if specialArgPath != null then
          specialArgPath
        else
          "${config.sshPaths.systemNamespaceDir}/ssh-keys.yaml";
      description = "Path to SOPS-decrypted runtime SSH keys YAML (from specialArgs.sshKeysYamlPath or default).";
    };

  };

  config = {
    # No config needed—this is a pure options module
  };
}
