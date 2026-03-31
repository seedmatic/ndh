{
  lib,
  config,
  ...
}:
let
  userHome = config.profile.user.home;
  xdgStateHome = config.xdg.stateHome or "${userHome}/.local/state";
in
{
  options.sshPaths = {
    # Darwin host SSH paths
    stateDir = lib.mkOption {
      type = lib.types.str;
      default = "${xdgStateHome}/ssh-key.d";
      description = "Base directory for SSH state files (keys, certificates).";
    };

    privKeyFile = lib.mkOption {
      type = lib.types.str;
      default = "${xdgStateHome}/ssh-key.d/host";
      description = "Path to the SSH host private key.";
    };

    hostCertPublic = lib.mkOption {
      type = lib.types.str;
      default = "${xdgStateHome}/ssh-key.d/host-mammoth-skate-host-cert.pub";
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
      default = "${xdgStateHome}/ssh-key.d/keys.yaml";
      description = "Path to the generated/extracted SSH keys YAML file (used by ssh-add-keys).";
    };
  };

  config = {
    # No config needed—this is a pure options module
  };
}
