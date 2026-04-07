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


    # Canonical per-user SSH material root
    secretsRootDir = lib.mkOption {
      type = lib.types.str;
      default = "${userHome}/.local/var/run/secrets";
      description = "Root directory for per-user SSH material in runtime secrets namespace.";
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

    keyName = lib.mkOption {
      type = lib.types.str;
      default = "rdp_host"; # minus translated key name for compatibility with existing conventions (e.g. yq shell output)
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
      default = lib.attrByPath [ "_module" "specialArgs" "sshKeysYamlPath" ] "/run/secrets/nix-darwin-home/ssh-keys.yaml" config;
      description = "Path to SOPS-decrypted runtime SSH keys YAML (from specialArgs.sshKeysYamlPath or default).";
    };

  };

  config = {
    # No config needed—this is a pure options module
  };
}
