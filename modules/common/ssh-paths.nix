{
  lib,
  config,
  ...
}:
let
  profileFromSpecialArgs = lib.attrByPath [ "_module" "specialArgs" "profile" ] { } config;
  profile =
    if config ? profile && config.profile != null then
      config.profile
    else
      profileFromSpecialArgs;

  userName =
    if profile ? user && profile.user ? name && profile.user.name != null then
      profile.user.name
    else if config ? home && config.home ? username && config.home.username != null then
      config.home.username
    else
      "user";
in
{
  options.sshPaths = {
    # Canonical system-scoped SSH material path (public/trust artifacts)
    systemSecretsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.perUserSecretsRoot}/${userName}/ssh-system-keys";
      description = "Base directory for system-owned SSH material (public keys/certs/CA metadata).";
    };

    # Canonical per-user SSH material root
    perUserSecretsRoot = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets-per-user";
      description = "Root directory for per-user SSH material in runtime secrets namespace.";
    };

    perUserSecretsDir = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.perUserSecretsRoot}/${userName}/ssh-keys";
      description = "Base directory for user-owned SSH material (private identities and user-local metadata).";
    };

    privKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.perUserSecretsDir}/host";
      description = "Path to the SSH host private key.";
    };

    hostCertPublic = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.systemSecretsDir}/host-mammoth-skate-host-cert.pub";
      description = "Path to the SSH host public certificate.";
    };

    etcKeysYamlFile = lib.mkOption {
      type = lib.types.str;
      default = "/etc/ssh/keys.yaml";
      description = "Path to the system SSH certificate principal validation YAML file (for sshd).";
    };

    # Home-manager SSH keys workflow paths
    runtimeSecretsKeysYaml = lib.mkOption {
      type = lib.types.str;
      default = "/run/secrets/nix-darwin-home/nxmatic-ssh-keys.yaml";
      description = "Path to SOPS-decrypted runtime SSH keys YAML (from specialArgs.sshKeysYamlPath or default).";
    };

    generatedKeysYamlFile = lib.mkOption {
      type = lib.types.str;
      default = "${config.sshPaths.perUserSecretsDir}/keys.yaml";
      description = "Path to the generated/extracted SSH keys YAML file (used by ssh-add-keys).";
    };
  };

  config = {
    # No config needed—this is a pure options module
  };
}
